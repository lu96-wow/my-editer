#lang racket

;;; tools/layers.rkt —— 依赖层次校验（目录 = 层，依赖只许向下）
;;;
;;; 规则：core 下每个模块有一个层号；它的相对 require 只能指向**同层或更低层**。
;;; 向上依赖 → 违约，退出码非零（`raco test tools` 里也是一条 check）。
;;;
;;; 这样「文件结构显式表达依赖方向」不只是文档约定，而是可执行契约。

(require racket/list racket/path racket/string racket/match racket/runtime-path)

(define-runtime-path here "layers.rkt")
(define root (simplify-path (build-path (path-only here) "..")))

;; 层号：越底越小。api 是低层公开门面（≤ viewport），editor 是 editor 平台入口。
(define rank-alist
  '(("core/atom"      . 0)
    ("core/unit"      . 1)
    ("core/doc"       . 2)
    ("core/viewport"  . 3)
    ("core/api.rkt"   . 3)
    ("core/platform"  . 4)
    ("core/editor.rkt" . 5)
    ("default-editor" . 6)))

;; core/ 下所有 .rkt（排除 compiled）
(define (rkt-files dir)
  (for/fold ([acc '()]) ([p (in-list (directory-list dir))])
    (define full (build-path dir p))
    (cond
      [(directory-exists? full)
       (if (equal? (file-name-from-path full) "compiled")
           acc
           (append (rkt-files full) acc))]
      [(regexp-match? #rx"[.]rkt$" (path->string p)) (cons full acc)]
      [else acc])))

(define (file->rank rel)
  (for/first ([p (in-list rank-alist)]
              #:when (or (string=? rel (car p))
                         (string-prefix? rel (string-append (car p) "/"))))
    (cdr p)))

(define (root-relative p) (path->string (find-relative-path root (simplify-path p))))

;; 扫描的层根：core（L0-L5）+ default-editor（L6）。
(define layer-roots (list (build-path root "core") (build-path root "default-editor")))
(define (all-rkt-files) (append* (map rkt-files layer-roots)))

;; 读 body 形态（去掉 #lang 行），收集**顶层** require 的字符串目标。
;; 只看生产依赖：module+ test 等子模块里的 require 不算（测试可以向上借更高层来驱动）。
(define (read-forms path)
  (define text (file->string path))
  (define body (regexp-replace #rx"^#lang[^\n]*\n" text ""))
  (let loop ([in (open-input-string body)] [acc '()])
    (define f (read in))
    (if (eof-object? f) (reverse acc) (loop in (cons f acc)))))

(define (collect-requires form)
  (cond
    [(and (pair? form) (eq? (car form) 'require))
     (for/list ([s (in-list (cdr form))] #:when (string? s)) s)]
    [else '()]))

(define (violations)
  (filter values
          (for*/list ([f (in-list (all-rkt-files))]
                      [spec (in-list (append* (map collect-requires (read-forms f))))])
            (define src-rank (file->rank (root-relative f)))
            (define tgt (simplify-path (build-path (path-only f) spec)))
            (define tgt-rank (file->rank (root-relative tgt)))
            (and src-rank tgt-rank (> tgt-rank src-rank)
                 (list (root-relative f) spec (root-relative tgt) src-rank tgt-rank)))))

(define (report)
  (define vs (violations))
  (for ([f (in-list (sort (all-rkt-files)
                          (lambda (a b) (string<? (path->string a) (path->string b)))))])
    (define rel (root-relative f))
    (printf "  L~a  ~a\n" (or (file->rank rel) '-) rel))
  (if (null? vs)
      (displayln "\n== 分层 OK：所有 require 都不向上 ==")
      (begin
        (displayln "\n== 违约（向上 require）==")
        (for ([v (in-list vs)])
          (match-define (list s spec t sr tr) v)
          (printf "  ~a  ->  ~a  (L~a -> L~a)\n" s spec sr tr)))))

(module+ main
  (report)
  (define vs (violations))
  (when (pair? vs) (error 'layers "依赖向上：~a" vs)))

(module+ test
  (require rackunit)
  (check-equal? (violations) '() "core 内 require 不得向上（见 tools/layers.rkt）"))
