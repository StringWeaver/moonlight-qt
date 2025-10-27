//
//  ScopedSignpost.h
//  Moonlight
//
//  Created by Larry Xia on 2025-10-24.
//

#pragma once

#if defined(NDEBUG) && defined(Q_OS_DARWIN)
#define SCOPED_SIGNPOST(...) ScopedSignpost _signpost_instance(__VA_ARGS__)
#else
#define SCOPED_SIGNPOST(...)
#endif
#define function_name(var) #var

#ifdef Q_OS_DARWIN
#include <os/signpost.h>
#include <string>
#include <cstdarg>
#include <cstdio>
class ScopedSignpost {
private:
    inline static os_log_t log = os_log_create("com.moonlight.app", "PointsOfInterest");
    os_signpost_id_t signpost_id;
    std::string name;
public:
    ScopedSignpost(const char* fmt, ...) {
        char buffer[256];
        va_list args;
        va_start(args, fmt);
        vsnprintf(buffer, sizeof(buffer), fmt, args);
        va_end(args);
        name = buffer;

        signpost_id = os_signpost_id_generate(log);
        os_signpost_interval_begin(log, signpost_id, function_name(__func__), "%{public}s", name.c_str());
    }

    ~ScopedSignpost() {
        os_signpost_interval_end(log, signpost_id, function_name(__func__), "%{public}s", name.c_str());
    }
};

#endif
