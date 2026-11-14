#lang racket

;;; edit-tui/persist/io.rkt —— 最小会话缓存的路径 / 单文件读写
;;;
;;; 只做纯 IO 和 workspace 相对路径转换；不理解 layout / buffer。
;;; 数据格式见 persist/minimal.rkt：一个 session.rktd，写 tmp + rename。

(require racket/file
         racket/path
         racket/string
         "../editor/resource.rkt")

(provide default-session-dir
         session-file-path
         session-backup-path
         read-session-data
         write-session-data!
         path->session
         session->path)

(define session-file-name "session.rktd")
(define session-backup-name "session.rktd.bak")

(define (default-session-dir root)
  (build-path (resource-normalize-path (or root (current-directory)))
              ".editdata"))

(define (session-file-path dir)
  (build-path dir session-file-name))

(define (session-backup-path file-or-dir)
  (define name (file-name-from-path file-or-dir))
  (define dir
    (if (and name (equal? (path->string name) session-file-name))
        (path-only file-or-dir)
        file-or-dir))
  (build-path dir session-backup-name))

;;; ════════════════ 读 ════════════════

;; 失败返回 #f（空文件 / read 失败 / 尾随数据）。调用方决定是否试 .bak。
(define (read-session-data file)
  (and (file-exists? file)
       (with-handlers ([exn:fail? (λ (_e) #f)])
         (call-with-input-file
          file
          (λ (in)
            (define v
              (parameterize ([read-accept-reader #f]
                             [read-accept-lang #f]
                             [read-accept-compiled #f])
                (read in)))
            (define trailing
              (parameterize ([read-accept-reader #f]
                             [read-accept-lang #f]
                             [read-accept-compiled #f])
                (read in)))
            (cond
              [(eof-object? v) #f]
              [(not (eof-object? trailing))
               (error 'read-session-data "session 文件有尾随数据：~a" file)]
              [else v]))))))

;;; ════════════════ 写 ════════════════

(define (ensure-gitignore! dir)
  (define p (build-path dir ".gitignore"))
  (unless (file-exists? p)
    (with-handlers ([exn:fail? void])
      (display-to-file "*\n" p #:exists 'error))))

(define (write-session-data! dir data)
  (make-directory* dir)
  (define file (session-file-path dir))
  (define bak (session-backup-path dir))
  (define tmp (build-path dir "session.rktd.tmp"))
  (call-with-output-file
   tmp
   #:exists 'truncate
   (λ (out)
     (write data out)
     (newline out)))
  (when (file-exists? file)
    (rename-file-or-directory file bak #t))
  (rename-file-or-directory tmp file #t)
  (ensure-gitignore! dir)
  (with-handlers ([exn:fail? void])
    (file-or-directory-permissions dir #o700)
    (file-or-directory-permissions file #o600))
  (void))

;;; ════════════════ workspace 相对路径 ════════════════

;; → #f | ((kind . workspace|absolute) (value . string))
(define (path->session root p)
  (if (not p)
      #f
      (let* ([p* (resource-normalize-path p)]
             [root* (and root (resource-normalize-path root))]
             [rel (and root*
                       (with-handlers ([exn:fail? (λ (_e) #f)])
                         (find-relative-path (string->path root*)
                                             (string->path p*))))]
             [rel-str (and rel (path->string rel))])
        (cond
          [(not root*) `((kind . absolute) (value . ,p*))]
          [(and rel
                (not (absolute-path? rel))
                (not (regexp-match? #rx"^\\.\\.[/\\\\]" rel-str)))
           `((kind . workspace) (value . ,rel-str))]
          [else `((kind . absolute) (value . ,p*))]))))

(define (session->path root data)
  (cond
    [(not data) #f]
    [else
     (let* ([kind (let ([p (and (list? data) (assq 'kind data))])
                    (and p (cdr p)))]
            [value (let ([p (and (list? data) (assq 'value data))])
                     (and p (cdr p)))])
       (cond
         [(not (string? value)) #f]
         [(eq? kind 'workspace)
          (let* ([root* (resource-normalize-path (or root (current-directory)))]
                 [vpath (string->path value)])
            (path->string
             (simplify-path
              (if (absolute-path? vpath)
                  vpath
                  (path->complete-path (build-path root* vpath))))))]
         [else (resource-normalize-path value)]))]))
