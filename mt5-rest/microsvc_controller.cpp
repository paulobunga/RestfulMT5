#include <boost/filesystem/operations.hpp>
#include <boost/filesystem/path.hpp>

#include "stdafx.h"
#include "microsvc_controller.hpp"
#include "types.hpp"

#define CMD_DOCS L"docs"
#define CMD_SUB L"sub"
#define CMD_SWAGGER L"swagger.json"
#define CMD_VERSION L"version"

using namespace web;
using namespace http;

static long long g_counter = 0;
static std::mutex g_counter_mutex;
static long long g_process_start_ticks = GetTickCount64();

#define CMD_HEALTH L"health"

utility::string_t MicroserviceController::makeRequestId() {
	std::lock_guard<std::mutex> lock(g_counter_mutex);
	g_counter++;
	SYSTEMTIME st;
	GetLocalTime(&st);
	wchar_t buf[64];
	swprintf_s(buf, 64, L"%04d%02d%02d%02d%02d%02d%03d-%lld",
		st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
		st.wMilliseconds, g_counter);
	return utility::string_t(buf);
}

const utility::string_t MicroserviceController::protocolVersion() {
	return U("1");
}

void MicroserviceController::initRestOpHandlers() {
	_listener.support(methods::GET, std::bind(&MicroserviceController::handleGet, this, std::placeholders::_1));
	_listener.support(methods::PUT, std::bind(&MicroserviceController::handlePut, this, std::placeholders::_1));
	_listener.support(methods::POST, std::bind(&MicroserviceController::handlePost, this, std::placeholders::_1));
	_listener.support(methods::DEL, std::bind(&MicroserviceController::handleDelete, this, std::placeholders::_1));
	_listener.support(methods::PATCH, std::bind(&MicroserviceController::handlePatch, this, std::placeholders::_1));
	_listener.support(methods::HEAD, std::bind(&MicroserviceController::handleHead, this, std::placeholders::_1));

	pushCommand(L"inited", endpoint());
}

void MicroserviceController::pushCommand(string_t command, string_t options) {
	web::json::value result = web::json::value::object();

	result[U("command")] = web::json::value::string(command);
	result[U("options")] = web::json::value::string(options);

	commands.push_back(ws2s(result.serialize()));
}

string MicroserviceController::popCommand() {
	if (commands.size() < 1)
		return string();
	string cmd = commands.front();
	commands.pop_front();
	return cmd;
}

size_t MicroserviceController::pendingCommands() {
	return commands.size();
}

int MicroserviceController::hasCommands() {
	return pendingCommands() > 0;
}

void MicroserviceController::setCommandResponse(const char* command, const char* response) {
	markMql5Connected();
	commandResponses.add(command, response);
}

void MicroserviceController::markMql5Connected() {
	mql5_connected.store(true, std::memory_order_relaxed);
}

void MicroserviceController::applyCorsHeaders(http_response & response) {
	response.headers().add(U("Access-Control-Allow-Origin"), U("*"));
	response.headers().add(U("Access-Control-Allow-Methods"), U("GET, POST, PUT, PATCH, DELETE, OPTIONS"));
	response.headers().add(U("Access-Control-Allow-Headers"), U("Content-Type, Authorization"));
}

http_response MicroserviceController::buildHealthResponse(bool mql5_connected, size_t queue_depth, long uptime_sec) {
	web::json::value body = web::json::value::object();
	body[U("status")] = web::json::value::string(U("ok"));
	body[U("mql5_connected")] = web::json::value::boolean(mql5_connected);
	body[U("queue_depth")] = web::json::value::number((int)queue_depth);
	body[U("uptime_sec")] = web::json::value::number(uptime_sec);
	http_response response(status_codes::OK);
	applyCorsHeaders(response);
	response.headers().add(U("Content-Type"), U("application/json"));
	response.set_body(body);
	return response;
}

http_response MicroserviceController::buildVersionResponse() {
	web::json::value body = web::json::value::object();
	body[U("version")] = web::json::value::string(protocolVersion());
	body[U("code")] = web::json::value::number(200);
	http_response response(status_codes::OK);
	applyCorsHeaders(response);
	response.headers().add(U("Content-Type"), U("application/json"));
	response.set_body(body);
	return response;
}

http_response MicroserviceController::formatStructuredError(int http_status, int code,
	const utility::string_t & message, const utility::string_t & request_id) {
	web::json::value body = web::json::value::object();
	body[U("code")] = web::json::value::number(code);
	body[U("message")] = web::json::value::string(message);
	body[U("request_id")] = web::json::value::string(request_id);
	http_response response(http_status);
	applyCorsHeaders(response);
	response.headers().add(U("Content-Type"), U("application/json"));
	response.set_body(body);
	return response;
}

bool MicroserviceController::waitForCommandResponse(const string & command, http_request & message,
	const utility::string_t & request_id, bool & timed_out,
	int & status_out, long long start_ticks) {
	if (command.size() > 7000) {
		status_out = 413;
		logRequest(message, status_out, start_ticks);
		message.reply(formatStructuredError(status_codes::RequestEntityTooLarge, 413,
			U("Command exceeds 7000 byte limit"), request_id));
		return true;
	}

	string value;
	if (commandResponses.wait_for(command, value, wait_timeout)) {
		status_out = 200;
		logRequest(message, status_out, start_ticks);
		http_response ok_response(status_codes::OK);
		applyCorsHeaders(ok_response);
		ok_response.headers().add(U("Content-Type"), U("application/json"));
		ok_response.set_body(value);
		message.reply(ok_response);
		commandResponses.remove(command);
		timed_out = false;
		return true;
	}

	status_out = 504;
	timed_out = true;
	return false;
}

void MicroserviceController::setCallback(const char* url, const char* format) {
	callback_url.clear();
	callback_format.clear();
	callback_url.append(s2ws(url));
	callback_format.append(s2ws(format));
}

void MicroserviceController::setCommandWaitTimeout(int timeout) {
	wait_timeout = timeout * 1000;
}

void MicroserviceController::setPath(const char *_path, const char* _url_swagger) {
	path_docs.clear();
	path_docs.append(_path);

	url_swagger.clear();
	url_swagger.append(_url_swagger);
}

int MicroserviceController::onEvent(const char* data) {
	if (callback_url.length() < 1)
		return -1;

	Concurrency::task<web::http::http_response> task;
	http_client callback_client(callback_url);

	try {
		if (callback_format == L"json") {
			task = callback_client.request(methods::POST, "", data);
		}
		else {
			http_request request(methods::POST);
			request.headers().add(L"Content-Type", L"application/x-www-form-urlencoded; charset=UTF-8");
			request.set_body(data);
			task = callback_client.request(request);
		}

		task.then([](http_response response) {
			if (response.status_code() == status_codes::OK) {
				auto body = response.extract_string().get();
				ucout << body << std::endl;
			}
		}).wait();

		return 1;
	}
	catch (const web::http::http_exception &e) {
		ucout << e.error_code() << endl;
	}
	catch (const std::exception & ex) {
		ucout << ex.what() << endl;
	}
	catch (...) {
	}

	return -1;
}

auto MicroserviceController::formatError(int code, const utility::string_t message) {
	web::json::value result = web::json::value::object();

	result[U("message")] = web::json::value::string(message);
	result[U("code")] = web::json::value::number(code);

	return result;
}

auto MicroserviceController::formatError(int code, const char* message) {
	wstring msg(message, message + strlen(message));

	return formatError(code, msg);
}

auto MicroserviceController::formatErrorRequired(utility::string_t field) {
	utility::string_t msg(field);

	msg.append(U(" is required"));

	return formatError(402, msg);
}

void MicroserviceController::handleGet(http_request message) {
	auto start_ticks = GetTickCount64();
	auto path = requestPath(message);
	auto params = requestQueryParams(message);
	utility::string_t request_id;

	try {
		if (path.size() > 0 && path[0] == CMD_HEALTH) {
			auto response = buildHealthResponse(mql5_connected.load(std::memory_order_relaxed), pendingCommands(),
				(long)((GetTickCount64() - g_process_start_ticks) / 1000));
			logRequest(message, 200, start_ticks);
			message.reply(response);
			return;
		}

		if (path.size() > 0 && path[0] == CMD_VERSION) {
			auto response = buildVersionResponse();
			logRequest(message, 200, start_ticks);
			message.reply(response);
			return;
		}

		if (path.size() > 0 && path[0] == CMD_DOCS) {
			string p(path_docs);
			p.append("docs.html");
			std::ifstream in(p, ios::in);

			http_response response(status_codes::OK);
			response.headers().add(L"Content-Type", L"text/html; charset=UTF-8");
			applyCorsHeaders(response);

			std::stringstream buffer;
			buffer << in.rdbuf();
			string b = buffer.str();
			in.close();

			response.set_body(b);
			logRequest(message, 200, start_ticks);
			message.reply(response);
			return;
		}

		if (path.size() < 1) {
			string p(path_docs);
			p.append("docs.html");
			std::ifstream in(p, ios::in);

			http_response response(status_codes::OK);
			response.headers().add(L"Content-Type", L"text/html; charset=UTF-8");
			applyCorsHeaders(response);

			std::stringstream buffer;
			buffer << in.rdbuf();
			string b = buffer.str();
			in.close();

			response.set_body(b);
			logRequest(message, 200, start_ticks);
			message.reply(response);

			return;
		}

		if (path[0] == CMD_SWAGGER) {
			string p(path_docs);
			p.append("swagger.json");
			std::ifstream in(p, ios::in);

			http_response response(status_codes::OK);
			response.headers().add(L"Content-Type", L"text/json; charset=UTF-8");
			applyCorsHeaders(response);

			std::stringstream buffer;
			buffer << in.rdbuf();
			string b = buffer.str();
			in.close();

			boost::algorithm::replace_all<string,string,string>(b, "localhost:6542", url_swagger);

			response.set_body(b);
			logRequest(message, 200, start_ticks);
			message.reply(response);

			return;
		}

		if (!token.empty()) {
			if (!message.headers().has(header_names::authorization)) {
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), makeRequestId()));
				return;
			}

			auto headers = message.headers();

			if (headers[header_names::authorization] != token) {
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), makeRequestId()));
				return;
			}
		}

		web::json::value result = web::json::value::object();
		request_id = makeRequestId();

		result[L"command"] = web::json::value::string(path[0]);

		if (path.size() > 1) {
			result[L"id"] = web::json::value::string(path[1]);
		}

		for (auto it = params.begin(); it != params.end(); ++it) {
			result[it->first] = web::json::value::string(it->second);
		}

		result[L"request_id"] = web::json::value::string(request_id);
		result[L"version"] = web::json::value::string(protocolVersion());

		string command = ws2s(result.serialize());

		if (command.size() > 7000) {
			logRequest(message, 413, start_ticks);
			message.reply(formatStructuredError(status_codes::RequestEntityTooLarge, 413,
				U("Command exceeds 7000 byte limit"), request_id));
			return;
		}

		if (!commands.push_back(command)) {
			logRequest(message, 503, start_ticks);
			message.reply(formatStructuredError(status_codes::ServiceUnavailable, 503,
				U("Command queue is full"), request_id));
			return;
		}

		bool timed_out = false;
		int status_out = 0;
		if (!waitForCommandResponse(command, message, request_id, timed_out, status_out, start_ticks)) {
			logRequest(message, status_out, start_ticks);
			message.reply(formatStructuredError(status_codes::GatewayTimeout, 504,
				U("Failed to get info, timeout"), request_id));
		}
	}
	catch (const FormatException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const RequiredException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const json::json_exception & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(ex.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << ex.what() << endl;
	}
	catch (...) {
		logRequest(message, 500, start_ticks);
		message.reply(formatStructuredError(status_codes::InternalError, 500,
			U("Internal Server Error"), request_id));
	}
}

void MicroserviceController::handlePost(http_request message) {
	auto start_ticks = GetTickCount64();
	utility::string_t request_id;

	try {
		auto path = requestPath(message);
		auto params = requestQueryParams(message);

		if (path.size() < 1) {
			request_id = makeRequestId();
			logRequest(message, 404, start_ticks);
			message.reply(formatStructuredError(status_codes::NotFound, 404,
				U("Not found"), request_id));
			return;
		}

		if (!token.empty()) {
			if (!message.headers().has(header_names::authorization)) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}

			auto headers = message.headers();

			if (headers[header_names::authorization] != token) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}
		}

		if (path[0] == CMD_SUB) {
			callback_url = params[U("callback_url")];
			callback_format = params[U("callback_format")];

			web::json::value body = web::json::value::object();
			body[U("message")] = json::value::string(L"Successfully subscribed");
			body[U("code")] = json::value::number(200);
			http_response response(status_codes::OK);
			applyCorsHeaders(response);
			response.headers().add(U("Content-Type"), U("application/json"));
			response.set_body(body);
			logRequest(message, 200, start_ticks);
			message.reply(response);

			return;
		}

		message.extract_utf8string(true).then([=](std::string body) {
			if (body.length() < 1) {
				throw exception("POST body is empty");
			}

			request_id = makeRequestId();

			std::size_t pos = body.find("}");
			std::string command = body.substr(0, pos);

			command.append(",\"command\":\"");
			command.append(ws2s(path[0]));
			command.append("\"");

			command.append(",\"request_id\":\"");
			command.append(ws2s(request_id));
			command.append("\"");

			command.append(",\"version\":\"");
			command.append(ws2s(protocolVersion()));
			command.append("\"}");

			if (command.size() > 7000) {
				logRequest(message, 413, start_ticks);
				message.reply(formatStructuredError(status_codes::RequestEntityTooLarge, 413,
					U("Command exceeds 7000 byte limit"), request_id));
				return;
			}

			if (!commands.push_back(command)) {
				logRequest(message, 503, start_ticks);
				message.reply(formatStructuredError(status_codes::ServiceUnavailable, 503,
					U("Command queue is full"), request_id));
				return;
			}

			bool timed_out = false;
			int status_out = 0;
			if (!waitForCommandResponse(command, message, request_id, timed_out, status_out, start_ticks)) {
				logRequest(message, status_out, start_ticks);
				message.reply(formatStructuredError(status_codes::GatewayTimeout, 504,
					U("Failed to get info, timeout"), request_id));
			}
		}).wait();

	}
	catch (const ManagerException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, e.code, msg, request_id));
	}
	catch (const FormatException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const RequiredException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const json::json_exception & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(ex.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << ex.what() << endl;
	}
	catch (...) {
		logRequest(message, 500, start_ticks);
		message.reply(formatStructuredError(status_codes::InternalError, 500,
			U("Internal Server Error"), request_id));
	}
}

void MicroserviceController::handleDelete(http_request message) {
	auto start_ticks = GetTickCount64();
	utility::string_t request_id;

	try {
		auto path = requestPath(message);

		if (path.size() < 1) {
			request_id = makeRequestId();
			logRequest(message, 404, start_ticks);
			message.reply(formatStructuredError(status_codes::NotFound, 404,
				U("Not found"), request_id));
			return;
		}

		if (!token.empty()) {
			if (!message.headers().has(header_names::authorization)) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}

			auto headers = message.headers();

			if (headers[header_names::authorization] != token) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}
		}

		request_id = makeRequestId();

		if (path.size() >= 2 && path[0] == L"orders") {
			web::json::value result = web::json::value::object();
			result[L"command"] = web::json::value::string(L"order_delete");
			result[L"id"] = web::json::value::string(path[1]);
			result[L"request_id"] = web::json::value::string(request_id);
			result[L"version"] = web::json::value::string(protocolVersion());

			string command = ws2s(result.serialize());

			if (command.size() > 7000) {
				logRequest(message, 413, start_ticks);
				message.reply(formatStructuredError(status_codes::RequestEntityTooLarge, 413,
					U("Command exceeds 7000 byte limit"), request_id));
				return;
			}

			if (!commands.push_back(command)) {
				logRequest(message, 503, start_ticks);
				message.reply(formatStructuredError(status_codes::ServiceUnavailable, 503,
					U("Command queue is full"), request_id));
				return;
			}

			bool timed_out = false;
			int status_out = 0;
			if (!waitForCommandResponse(command, message, request_id, timed_out, status_out, start_ticks)) {
				logRequest(message, status_out, start_ticks);
				message.reply(formatStructuredError(status_codes::GatewayTimeout, 504,
					U("Failed to get info, timeout"), request_id));
			}
			return;
		}

		if (path.size() >= 2 && path[0] == L"positions") {
			web::json::value result = web::json::value::object();
			result[L"command"] = web::json::value::string(L"position_delete");
			result[L"id"] = web::json::value::string(path[1]);
			result[L"request_id"] = web::json::value::string(request_id);
			result[L"version"] = web::json::value::string(protocolVersion());

			string command = ws2s(result.serialize());

			if (command.size() > 7000) {
				logRequest(message, 413, start_ticks);
				message.reply(formatStructuredError(status_codes::RequestEntityTooLarge, 413,
					U("Command exceeds 7000 byte limit"), request_id));
				return;
			}

			if (!commands.push_back(command)) {
				logRequest(message, 503, start_ticks);
				message.reply(formatStructuredError(status_codes::ServiceUnavailable, 503,
					U("Command queue is full"), request_id));
				return;
			}

			bool timed_out = false;
			int status_out = 0;
			if (!waitForCommandResponse(command, message, request_id, timed_out, status_out, start_ticks)) {
				logRequest(message, status_out, start_ticks);
				message.reply(formatStructuredError(status_codes::GatewayTimeout, 504,
					U("Failed to get info, timeout"), request_id));
			}
			return;
		}

		logRequest(message, 404, start_ticks);
		message.reply(formatStructuredError(status_codes::NotFound, 404,
			U("Not found"), request_id));
	}
	catch (const ManagerException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, e.code, msg, request_id));
	}
	catch (const FormatException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const RequiredException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const json::json_exception & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(ex.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << ex.what() << endl;
	}
	catch (...) {
		logRequest(message, 500, start_ticks);
		message.reply(formatStructuredError(status_codes::InternalError, 500,
			U("Internal Server Error"), request_id));
	}
}

void MicroserviceController::handlePut(http_request message) {
	auto start_ticks = GetTickCount64();
	utility::string_t request_id;

	try {
		auto path = requestPath(message);

		if (path.size() < 1) {
			request_id = makeRequestId();
			logRequest(message, 404, start_ticks);
			message.reply(formatStructuredError(status_codes::NotFound, 404,
				U("Not found"), request_id));
			return;
		}

		if (!token.empty()) {
			if (!message.headers().has(header_names::authorization)) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}

			auto headers = message.headers();

			if (headers[header_names::authorization] != token) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}
		}

		request_id = makeRequestId();

		message.extract_utf8string(true).then([=](std::string body) {
			if (body.length() < 1) {
				throw exception("PUT body is empty");
			}

			web::json::value result = web::json::value::object();
			utility::string_t cmd_name;

			if (path.size() >= 2 && path[0] == L"orders") {
				cmd_name = L"order_modify";
				result[L"command"] = web::json::value::string(cmd_name);
				result[L"id"] = web::json::value::string(path[1]);
			}
			else if (path.size() >= 2 && path[0] == L"positions") {
				cmd_name = L"position_modify";
				result[L"command"] = web::json::value::string(cmd_name);
				result[L"id"] = web::json::value::string(path[1]);
			}
			else {
				throw exception("Unknown resource for PUT");
			}

			std::size_t pos = body.find("}");
			string payload = body.substr(0, pos);
			payload.append(",\"command\":\"");
			payload.append(ws2s(cmd_name));
			payload.append("\",\"id\":\"");
			payload.append(ws2s(result[L"id"].as_string()));
			payload.append("\",\"request_id\":\"");
			payload.append(ws2s(request_id));
			payload.append("\",\"version\":\"");
			payload.append(ws2s(protocolVersion()));
			payload.append("\"}");

			if (payload.size() > 7000) {
				logRequest(message, 413, start_ticks);
				message.reply(formatStructuredError(status_codes::RequestEntityTooLarge, 413,
					U("Command exceeds 7000 byte limit"), request_id));
				return;
			}

			if (!commands.push_back(payload)) {
				logRequest(message, 503, start_ticks);
				message.reply(formatStructuredError(status_codes::ServiceUnavailable, 503,
					U("Command queue is full"), request_id));
				return;
			}

			bool timed_out = false;
			int status_out = 0;
			if (!waitForCommandResponse(payload, message, request_id, timed_out, status_out, start_ticks)) {
				logRequest(message, status_out, start_ticks);
				message.reply(formatStructuredError(status_codes::GatewayTimeout, 504,
					U("Failed to get info, timeout"), request_id));
			}
		}).wait();

	}
	catch (const ManagerException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, e.code, msg, request_id));
	}
	catch (const FormatException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const RequiredException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const json::json_exception & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(ex.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << ex.what() << endl;
	}
	catch (...) {
		logRequest(message, 500, start_ticks);
		message.reply(formatStructuredError(status_codes::InternalError, 500,
			U("Internal Server Error"), request_id));
	}
}

void MicroserviceController::handlePatch(http_request message) {
	auto start_ticks = GetTickCount64();
	utility::string_t request_id;

	try {
		auto path = requestPath(message);

		if (path.size() < 1) {
			request_id = makeRequestId();
			logRequest(message, 404, start_ticks);
			message.reply(formatStructuredError(status_codes::NotFound, 404,
				U("Not found"), request_id));
			return;
		}

		if (!token.empty()) {
			if (!message.headers().has(header_names::authorization)) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}

			auto headers = message.headers();

			if (headers[header_names::authorization] != token) {
				request_id = makeRequestId();
				logRequest(message, 401, start_ticks);
				message.reply(formatStructuredError(status_codes::Unauthorized, 401,
					U("Unauthorized"), request_id));
				return;
			}
		}

		request_id = makeRequestId();

		message.extract_utf8string(true).then([=](std::string body) {
			if (body.length() < 1) {
				throw exception("PATCH body is empty");
			}

			web::json::value result = web::json::value::object();
			utility::string_t cmd_name;

			if (path.size() >= 2 && path[0] == L"orders") {
				cmd_name = L"order_modify";
				result[L"command"] = web::json::value::string(cmd_name);
				result[L"id"] = web::json::value::string(path[1]);
			}
			else if (path.size() >= 2 && path[0] == L"positions") {
				cmd_name = L"position_modify";
				result[L"command"] = web::json::value::string(cmd_name);
				result[L"id"] = web::json::value::string(path[1]);
			}
			else {
				throw exception("Unknown resource for PATCH");
			}

			std::size_t pos = body.find("}");
			string payload = body.substr(0, pos);
			payload.append(",\"command\":\"");
			payload.append(ws2s(cmd_name));
			payload.append("\",\"id\":\"");
			payload.append(ws2s(result[L"id"].as_string()));
			payload.append("\",\"request_id\":\"");
			payload.append(ws2s(request_id));
			payload.append("\",\"version\":\"");
			payload.append(ws2s(protocolVersion()));
			payload.append("\"}");

			if (payload.size() > 7000) {
				logRequest(message, 413, start_ticks);
				message.reply(formatStructuredError(status_codes::RequestEntityTooLarge, 413,
					U("Command exceeds 7000 byte limit"), request_id));
				return;
			}

			if (!commands.push_back(payload)) {
				logRequest(message, 503, start_ticks);
				message.reply(formatStructuredError(status_codes::ServiceUnavailable, 503,
					U("Command queue is full"), request_id));
				return;
			}

			bool timed_out = false;
			int status_out = 0;
			if (!waitForCommandResponse(payload, message, request_id, timed_out, status_out, start_ticks)) {
				logRequest(message, status_out, start_ticks);
				message.reply(formatStructuredError(status_codes::GatewayTimeout, 504,
					U("Failed to get info, timeout"), request_id));
			}
		}).wait();

	}
	catch (const ManagerException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, e.code, msg, request_id));
	}
	catch (const FormatException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const RequiredException & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 405, msg, request_id));
	}
	catch (const json::json_exception & e) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(e.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << e.what() << endl;
	}
	catch (const std::exception & ex) {
		logRequest(message, 400, start_ticks);
		utility::string_t msg = s2ws(std::string(ex.what()));
		message.reply(formatStructuredError(status_codes::BadRequest, 410, msg, request_id));
		ucout << ex.what() << endl;
	}
	catch (...) {
		logRequest(message, 500, start_ticks);
		message.reply(formatStructuredError(status_codes::InternalError, 500,
			U("Internal Server Error"), request_id));
	}
}

void MicroserviceController::handleHead(http_request message) {
	auto start_ticks = GetTickCount64();
	auto response = buildVersionResponse();
	logRequest(message, 200, start_ticks);
	message.reply(response);
}

void MicroserviceController::handleOptions(http_request message) {
	auto start_ticks = GetTickCount64();
	http_response response(status_codes::OK);
	applyCorsHeaders(response);
	response.headers().add(U("Allow"), U("GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD"));
	logRequest(message, 200, start_ticks);
	message.reply(response);
}

void MicroserviceController::handleTrace(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::TRCE));
}

void MicroserviceController::handleConnect(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::CONNECT));
}

void MicroserviceController::handleMerge(http_request message) {
	message.reply(status_codes::NotImplemented, responseNotImpl(methods::MERGE));
}

json::value MicroserviceController::responseNotImpl(const http::method & method) {
	using namespace json;

	auto response = value::object();
	response[U("serviceName")] = value::string(U("MT5 REST"));
	response[U("http_method")] = value::string(method);

	return response;
}

void MicroserviceController::logRequest(const http_request & request, int status, long long start_ticks) {
	long long duration = GetTickCount64() - start_ticks;
	auto path = requestPath(request);
	utility::string_t path_str;
	for (size_t i = 0; i < path.size(); i++) {
		if (i > 0) path_str += U("/");
		path_str += path[i];
	}
	if (path_str.empty()) path_str = U("/");
	ucout << request.method() << U(" ") << path_str << U(" ") << status
		<< U(" ") << duration << U("ms") << std::endl;
}
