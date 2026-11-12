//  CrashLog.swift — why the app died last time.
//
//  A crash does not run `catch`. A Swift fatal error, a failed force-unwrap, a
//  bad pointer or an out-of-memory kill all take the process down without
//  giving it a chance to report anything, which is why importing a photo
//  "just closes" with no message anywhere.
//
//  The only thing the app itself can do is leave a note before it goes:
//  `NSSetUncaughtExceptionHandler` for Objective-C exceptions, and a handler
//  per fatal signal for everything below that. The next launch reads the note
//  and puts it on screen.
//
//  The handlers are file-scope functions, not closures: `signal` takes a
//  `@convention(c)` pointer, and Swift will not form one from a closure that
//  captures context ("a C function pointer cannot be formed from a closure
//  that captures context").
//
//  They deliberately do very little. `UserDefaults` is not async-signal-safe,
//  but it is the only storage reachable without opening a file inside a signal
//  handler, and a note that occasionally fails to land is better than none.
//  After recording, the default handler is restored and the signal re-raised
//  so iOS still writes its own `.ips` report.

import Foundation

/// Objective-C exceptions that would otherwise terminate silently.
private func spektraUncaughtException(_ exception: NSException) {
    CrashLog.record("exception \(exception.name.rawValue) — \(exception.reason ?? "no reason")")
}

/// Fatal signals: bad access, abort, bad instruction, arithmetic, trap.
private func spektraFatalSignal(_ received: Int32) {
    CrashLog.record("signal \(received)")
    // Hand the signal back to the system so the .ips report is still written.
    signal(received, SIG_DFL)
    raise(received)
}

enum CrashLog {

    private static let key = "lastCrash"

    /// Install the handlers. Call once, as early as possible.
    static func install() {
        NSSetUncaughtExceptionHandler(spektraUncaughtException)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, spektraFatalSignal)
        }
    }

    /// Leave the note. Called from a signal handler, so it stays small.
    static func record(_ text: String) {
        UserDefaults.standard.set(text, forKey: key)
        UserDefaults.standard.synchronize()
    }

    /// The note left by the previous run, consumed once.
    static func take() -> String? {
        let value = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }
}
