#ifndef SAFEMAP_HPP
#define SAFEMAP_HPP

#include <map>
#include <mutex>
#include <condition_variable>
#include <string>

using namespace std;

class SafeMap {
public:
	SafeMap() : data(), mut(), cond() {}
	SafeMap(const SafeMap& orig) : data(orig.data), mut(), cond() {}
	~SafeMap() {}

	void add(string key, string value);
	bool contains(string key);
	void remove(string key);
	bool try_get(const string &key, string &value);
	bool wait_for(const string &key, string &value, int timeout_ms);

private:
	map<string,string> data;
	mutable mutex mut;
	condition_variable cond;
};

#endif /* SAFEMAP_HPP */
