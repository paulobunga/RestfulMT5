#include "stdafx.h"
#include <string>
#include <utility>
#include "safe_vector.hpp"

void SafeVector::set_max_size(size_t n) {
	lock_guard<mutex> lock(mut);
	max_size_ = n;
	use_bound_ = (n > 0);
}

bool SafeVector::push_back(string in) {
	lock_guard<mutex> lock(mut);
	if (use_bound_ && vec.size() >= max_size_)
		return false;
	vec.push_back(move(in));
	cond.notify_one();
	return true;
}

string SafeVector::pop_front() {
	lock_guard<mutex> lock(mut);
	if (vec.empty())
		return string();
	string out = move(vec.front());
	vec.erase(vec.begin());
	cond.notify_one();
	return out;
}

string SafeVector::front() {
	lock_guard<mutex> lock(mut);
	if (vec.empty())
		return string();
	return vec.front();
}

size_t SafeVector::size() {
	lock_guard<mutex> lock(mut);
	return vec.size();
}

string& SafeVector::operator[](const int index) {
	lock_guard<mutex> lock(mut);
	return vec[index];
}

vector<string> SafeVector::toVector() {
	lock_guard<mutex> lock(mut);
	return vec;
}
