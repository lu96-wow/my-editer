#lang racket

;;; edit-tui/lang/c/base/keywords.rkt —— C 关键字 / 类型 / 常量（纯）
;;;
;;; 只做 word -> category；配色 / 补全自己决定怎么用。

(require racket/list)

(provide c-keyword?
         c-type?
         c-constant?
         c-keyword-names
         c-type-names
         c-constant-names
         c-preprocessor-directives)

(define c-keyword-names
  '(auto break case const continue default do else enum extern for goto if
    inline register restrict return sizeof static struct switch typedef union
    volatile while
    _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local
    __attribute__ __extension__ __inline__ __restrict))

(define c-type-names
  '(void char short int long float double signed unsigned _Bool _Complex
    _Imaginary bool
    size_t ssize_t ptrdiff_t wchar_t wint_t
    int8_t int16_t int32_t int64_t
    uint8_t uint16_t uint32_t uint64_t
    intptr_t uintptr_t
    intmax_t uintmax_t
    off_t mode_t pid_t uid_t gid_t socklen_t useconds_t
    time_t clock_t
    FILE DIR va_list
    sigset_t
    pthread_t pthread_mutex_t pthread_cond_t pthread_rwlock_t pthread_key_t
    struct union enum))

(define c-constant-names
  '(NULL EOF true false
    INT_MAX INT_MIN UINT_MAX LONG_MAX LONG_MIN ULONG_MAX
    LLONG_MAX LLONG_MIN ULLONG_MAX
    CHAR_MAX CHAR_MIN SCHAR_MAX SCHAR_MIN UCHAR_MAX
    SHRT_MAX SHRT_MIN USHRT_MAX
    SIZE_MAX PTRDIFF_MAX PATH_MAX NAME_MAX
    stdin stdout stderr
    errno
    O_RDONLY O_WRONLY O_RDWR O_CREAT O_TRUNC O_APPEND O_NONBLOCK O_CLOEXEC
    SEEK_SET SEEK_CUR SEEK_END
    PROT_READ PROT_WRITE PROT_EXEC PROT_NONE
    MAP_SHARED MAP_PRIVATE MAP_ANONYMOUS MAP_FAILED
    AF_INET AF_INET6 AF_UNIX
    SOCK_STREAM SOCK_DGRAM SOCK_RAW
    POLLIN POLLOUT POLLERR POLLHUP
    SIGINT SIGTERM SIGKILL SIGSEGV SIGCHLD SIGPIPE
    RTLD_LAZY RTLD_NOW RTLD_GLOBAL RTLD_LOCAL
    STDIN_FILENO STDOUT_FILENO STDERR_FILENO
    EXIT_SUCCESS EXIT_FAILURE
    CLOCK_REALTIME CLOCK_MONOTONIC
    LC_ALL LC_CTYPE LC_NUMERIC LC_TIME))

(define c-preprocessor-directives
  '("include" "define" "undef" "if" "ifdef" "ifndef" "else" "elif" "endif"
    "error" "warning" "pragma" "line" "include_next"))

(define (name->string x) (if (symbol? x) (symbol->string x) x))

(define keyword-set
  (for/hash ([x (in-list c-keyword-names)])
    (values (name->string x) #t)))
(define type-set
  (for/hash ([x (in-list c-type-names)])
    (values (name->string x) #t)))
(define constant-set
  (for/hash ([x (in-list c-constant-names)])
    (values (name->string x) #t)))

(define (c-keyword? s) (and (string? s) (hash-has-key? keyword-set s)))
(define (c-type? s) (and (string? s) (hash-has-key? type-set s)))
(define (c-constant? s) (and (string? s) (hash-has-key? constant-set s)))
