#lang racket/base

;;; import-tables.rkt —— 从 racket-translate-lang-build 的 tables 生成插件数据
;;;
;;; 输入：
;;;   <from>/.../*.rktd
;;;     第一行 : CN symbol -> EN symbol
;;;     第二行 : CN keyword -> EN keyword
;;;     第三行 : re-export deps（这里不用）
;;;
;;; 输出：
;;;   <to> : 两行数据文件，插件运行时直接 read
;;;     1. CN symbol -> EN symbol
;;;     2. CN keyword -> EN keyword
;;;
;;; 不直接复制 396 个 .rktd：合并成一个有序数据文件，启动时只需读一次。
;;;
;;; 用法：
;;;   racket plugins/bilingual/scripts/import-tables.rkt \
;;;     --from /home/lu96/work/racket-translate-lang-build/dist/racket-cn/tables

(require racket/cmdline
         racket/file
         racket/list
         racket/path)

(define (rktd-file? p)
  (regexp-match? #rx"[.]rktd$" (path->string p)))

(define (walk-rktd dir acc)
  (cond
    [(not (directory-exists? dir)) acc]
    [else
     (for/fold ([acc acc]) ([f (in-list (directory-list dir))])
       (define full (build-path dir f))
       (cond
         [(directory-exists? full) (walk-rktd full acc)]
         [(rktd-file? full) (cons full acc)]
         [else acc]))]))

(define (load-tables from)
  (define id-table (make-hash))
  (define kw-table (make-hash))
  (define files (walk-rktd from '()))
  (for ([f (in-list files)])
    (call-with-input-file f
      (lambda (in)
        (define id (read in))
        (define kw (read in))
        (void (read in))
        (when (hash? id)
          (for ([(cn en) (in-hash id)])
            (hash-set! id-table cn en)))
        (when (hash? kw)
          (for ([(cn en) (in-hash kw)])
            (hash-set! kw-table cn en))))))
  (values files id-table kw-table))

(define (write-tables! out-path id-table kw-table)
  (make-directory* (path-only out-path))
  (define id-list
    (sort (hash->list id-table) symbol<? #:key car))
  (define kw-list
    (sort (hash->list kw-table) keyword<? #:key car))
  (call-with-output-file out-path #:exists 'replace
    (lambda (out)
      (write (make-immutable-hash id-list) out)
      (newline out)
      (write (make-immutable-hash kw-list) out)
      (newline out))))

(module+ main
  (define from (make-parameter #f))
  (define to (make-parameter #f))
  (command-line
   #:once-each
   ["--from" dir "racket-translate-lang-build tables directory" (from dir)]
   ["--to" file "output .rktd path (default: ../data/racket-zh.rktd)"
    (to file)]
   #:args () (void))

  (unless (from)
    (eprintf "usage: import-tables.rkt --from <tables-dir> [--to <out.rktd>]\n")
    (exit 1))

  (define script-path (path->complete-path (find-system-path 'run-file)))
  (define out-path
    (simplify-path
     (path->complete-path
      (or (to)
          (build-path (path-only script-path) ".." "data" "racket-zh.rktd")))))

  (printf "=== import bilingual tables ===\n")
  (printf "from: ~a\n" (from))
  (define-values (files id-table kw-table) (load-tables (from)))
  (printf "read ~a tables: ~a symbols, ~a keywords\n"
          (length files) (hash-count id-table) (hash-count kw-table))
  (write-tables! out-path id-table kw-table)
  (printf "wrote: ~a (~a bytes)\n" out-path (file-size out-path)))
