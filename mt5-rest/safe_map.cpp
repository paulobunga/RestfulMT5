#include "stdafx.h"
#include <string>
#include <utility>
#include <chrono>
#include "safe_map.hpp"

void SafeMap::add(string key, string value) {
	lock_guard<mutex> lock(mut);
	data[key] = move(value);
	cond.notify_all();
}

bool SafeMap::contains(string key) {
	lock_guard<mutex> lock(mut);
	return data.count(key) > 0;
}

void SafeMap::remove(string key) {
	lock_guard<mutex> lock(mut);
	data.erase(key);
	cond.notify_all();
}

bool SafeMap::try_get(const string &key, string &value) {
	lock_guard<mutex> lock(mut);
	auto it = data.find(key);
	if (it == data.end())
		return false;
	value = it->second;
	data.erase(it);
	cond.notify_all();
	return true;
}

bool SafeMap::wait_for(const string &key, string &value, int timeout_ms) {
	unique_lock<mutex> lock(mut);
	auto pred = [&]() { return data.count(key) > 0; };
	bool found = cond.wait_for(lock, chrono::milliseconds(timeout_ms), pred);
	if (found) {
		value = data[key];
		data.erase(key);
		cond.notify_all();
	}
	return found;
}
