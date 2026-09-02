#ifndef SAFEVECTOR_HPP
#define SAFEVECTOR_HPP

#include <vector>
#include <mutex>
#include <condition_variable>
#include <string>
using namespace std;

class SafeVector {
public:
	SafeVector() : vec(), mut(), cond(), max_size_(256), use_bound_(false) {}
	SafeVector(const SafeVector& orig) : vec(orig.vec), mut(), cond(),
		max_size_(orig.max_size_), use_bound_(orig.use_bound_) {}
	~SafeVector() {}

	void set_max_size(size_t n);
	bool push_back(string in);
	string pop_front();
	string front();
	size_t size();
	string& operator[](const int index);
	vector<string> toVector();

private:
	vector<string> vec;
	mutable mutex mut;
	condition_variable cond;
	size_t max_size_;
	bool use_bound_;
};
