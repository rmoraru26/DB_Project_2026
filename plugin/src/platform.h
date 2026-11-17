// Small portability layer for the campus_audit plugin.
//
// The plugin is built both as a Linux shared object (loaded by the official
// MariaDB Docker image) and as a Windows DLL (loaded by the official MariaDB
// Windows build).  Only the primitives the plugin really needs live here:
// a mutex, a reader/writer lock, a wall-clock timestamp and the process id.

#ifndef CAMPUS_AUDIT_PLATFORM_H
#define CAMPUS_AUDIT_PLATFORM_H

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <pthread.h>
#include <sys/time.h>
#include <unistd.h>
#endif

namespace campus_audit {

class Mutex {
public:
#ifdef _WIN32
    Mutex() { InitializeSRWLock(&lock_); }
    void lock() { AcquireSRWLockExclusive(&lock_); }
    void unlock() { ReleaseSRWLockExclusive(&lock_); }
private:
    SRWLOCK lock_;
#else
    Mutex() { pthread_mutex_init(&lock_, nullptr); }
    ~Mutex() { pthread_mutex_destroy(&lock_); }
    void lock() { pthread_mutex_lock(&lock_); }
    void unlock() { pthread_mutex_unlock(&lock_); }
private:
    pthread_mutex_t lock_;
#endif
    Mutex(const Mutex&) = delete;
    Mutex& operator=(const Mutex&) = delete;
};

class RwLock {
public:
#ifdef _WIN32
    RwLock() { InitializeSRWLock(&lock_); }
    void read_lock() { AcquireSRWLockShared(&lock_); }
    void read_unlock() { ReleaseSRWLockShared(&lock_); }
    void write_lock() { AcquireSRWLockExclusive(&lock_); }
    void write_unlock() { ReleaseSRWLockExclusive(&lock_); }
private:
    SRWLOCK lock_;
#else
    RwLock() { pthread_rwlock_init(&lock_, nullptr); }
    ~RwLock() { pthread_rwlock_destroy(&lock_); }
    void read_lock() { pthread_rwlock_rdlock(&lock_); }
    void read_unlock() { pthread_rwlock_unlock(&lock_); }
    void write_lock() { pthread_rwlock_wrlock(&lock_); }
    void write_unlock() { pthread_rwlock_unlock(&lock_); }
private:
    pthread_rwlock_t lock_;
#endif
    RwLock(const RwLock&) = delete;
    RwLock& operator=(const RwLock&) = delete;
};

template <typename L>
class LockGuard {
public:
    explicit LockGuard(L& l) : l_(l) { l_.lock(); }
    ~LockGuard() { l_.unlock(); }
private:
    L& l_;
};

// Seconds and microseconds since the Unix epoch (UTC).
inline void wall_clock(long long* sec, long* usec) {
#ifdef _WIN32
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    unsigned long long t = (static_cast<unsigned long long>(ft.dwHighDateTime) << 32)
                           | ft.dwLowDateTime;
    // FILETIME counts 100 ns intervals since 1601-01-01.
    t -= 116444736000000000ULL;
    *sec = static_cast<long long>(t / 10000000ULL);
    *usec = static_cast<long>((t % 10000000ULL) / 10ULL);
#else
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    *sec = static_cast<long long>(tv.tv_sec);
    *usec = static_cast<long>(tv.tv_usec);
#endif
}

inline unsigned long process_id() {
#ifdef _WIN32
    return static_cast<unsigned long>(GetCurrentProcessId());
#else
    return static_cast<unsigned long>(getpid());
#endif
}

}  // namespace campus_audit

#endif
