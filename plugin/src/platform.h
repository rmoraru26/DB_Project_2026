// Small portability layer for the campus_audit plugin.
//
// The plugin is built both as a Linux shared object (loaded by the official
// MariaDB Docker image) and as a Windows DLL (loaded by the official MariaDB
// Windows build).  Only the primitives the plugin really needs live here:
// a mutex (with a bounded wait), a reader/writer lock, a wall-clock
// timestamp and the process id.

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
    bool try_lock() { return TryAcquireSRWLockExclusive(&lock_) != 0; }
private:
    SRWLOCK lock_;
#else
    Mutex() { pthread_mutex_init(&lock_, nullptr); }
    ~Mutex() { pthread_mutex_destroy(&lock_); }
    void lock() { pthread_mutex_lock(&lock_); }
    void unlock() { pthread_mutex_unlock(&lock_); }
    bool try_lock() { return pthread_mutex_trylock(&lock_) == 0; }
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

inline void sleep_ms(unsigned ms) {
#ifdef _WIN32
    Sleep(ms);
#else
    usleep(static_cast<useconds_t>(ms) * 1000);
#endif
}

const unsigned kWaitForever = ~0u;

// Like LockGuard, but gives up after about timeout_ms; owns() says whether
// the lock was taken.  It polls, because an SRWLOCK has no timed wait.
// kWaitForever waits like LockGuard.
template <typename L>
class TimedLockGuard {
public:
    TimedLockGuard(L& l, unsigned timeout_ms) : l_(l), owns_(false) {
        if (timeout_ms == kWaitForever) {
            l_.lock();
            owns_ = true;
            return;
        }
        owns_ = l_.try_lock();
        for (unsigned waited = 0; !owns_ && waited < timeout_ms; waited += 5) {
            sleep_ms(5);
            owns_ = l_.try_lock();
        }
    }
    ~TimedLockGuard() {
        if (owns_) l_.unlock();
    }
    bool owns() const { return owns_; }
    TimedLockGuard(const TimedLockGuard&) = delete;
    TimedLockGuard& operator=(const TimedLockGuard&) = delete;
private:
    L& l_;
    bool owns_;
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
