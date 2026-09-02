#pragma once 

#include <locale>
#include <codecvt>

#include <boost/algorithm/string/replace.hpp>
#include <cpprest/http_client.h>
#include "basic_controller.hpp"
#include "session_manager.hpp"
#include "safe_vector.hpp"
#include "safe_map.hpp"

using namespace cfx;
using namespace std;
using namespace utility;
using namespace web::http::client;

static string ws2s(const std::wstring& wstr) {
	using convert_typeX = std::codecvt_utf8<wchar_t>;
	std::wstring_convert<convert_typeX, wchar_t> converterX;

	return converterX.to_bytes(wstr);
};

static wstring s2ws(const std::string& str) {
	using convert_typeX = std::codecvt_utf8<wchar_t>;
	std::wstring_convert<convert_typeX, wchar_t> converterX;

	return converterX.from_bytes(str);
};

class MicroserviceController : public BasicController, Controller {
public:
	MicroserviceController() : BasicController() {}
	~MicroserviceController() {
	}
	void handleGet(http_request message) override;
	void handlePut(http_request message) override;
	void handlePost(http_request message) override;
	void handlePatch(http_request message) override;
	void handleDelete(http_request message) override;
	void handleHead(http_request message) override;
	void handleOptions(http_request message) override;
	void handleTrace(http_request message) override;
	void handleConnect(http_request message) override;
	void handleMerge(http_request message) override;
	void initRestOpHandlers() override;

	auto formatError(int code, const utility::string_t message);
	auto formatError(int code, const char* message);
	auto formatErrorRequired(utility::string_t field);

	void setCommandResponse(const char* command, const char* reponse);
	void pushCommand(string_t command, string_t options);
	int hasCommands();
	int onEvent(const char* data);
	void setCommandWaitTimeout(int timeout);
	void setPath(const char* path, const char* url_swaggger);
	void setCallback(const char* url, const char* format);
	void setAuthToken(const char* _token) {
		token.clear();
		token.append(s2ws(_token));
	};

	string popCommand();
	size_t pendingCommands();

private:
	bool mql5_connected = false;
	std::mutex mql5_conn_mutex;

	static json::value responseNotImpl(const http::method & method);
	static utility::string_t makeRequestId();
	static const utility::string_t protocolVersion();
	static void applyCorsHeaders(http_response & response);
	static http_response buildHealthResponse(bool mql5_connected, size_t queue_depth, long uptime_sec);
	static http_response buildVersionResponse();
	http_response formatStructuredError(int http_status, int code,
		const utility::string_t & message, const utility::string_t & request_id);
	bool waitForCommandResponse(const string & command, http_request & message,
		const utility::string_t & request_id, bool & timed_out);
	void markMql5Connected();
	void logRequest(const http_request & request, int status, long long start_ticks);

	SafeVector commands;
	SafeMap commandResponses;
	string_t callback_url;
	string_t callback_format;
	int wait_timeout;
	string path_docs;
	string url_swagger;
	string_t token;
};
