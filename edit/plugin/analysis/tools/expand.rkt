#lang racket

;;; edit/plugin/analysis/tools/expand.rkt —— drracket/check-syntax 展开 + collector（纯）
;;;
;;; 一次展开（collector 扇出）产出 expand-result：
;;;   · sem-tokens ：lexically-bound / set!d 标识符 → variable；定义点加 definition 修饰
;;;   · definitions：定义点（syncheck:add-definition-target）
;;;   · uses       ：本文件词法使用（color-range 去掉定义点）+ 跨文件使用（jump-to-definition）
;;;   · diagnostics：读取 / 展开失败时的粗粒度 error
;;;
;;; 报位：syncheck 回调是 **0-based**（traversal 已做 syntax-position-1），直接用。
;;;
;;; ⚠ expand 会执行被打开文件的编译期代码（#lang / 宏）。**只允许经 worker.rkt 调用**，
;;;   绝不在 UI 线程直接调。本模块本身不做沙箱（沙箱在 worker 层）。

(require racket/class
         racket/list
         racket/port
         syntax/modread
         drracket/check-syntax
         "span.rkt")

(provide expand-analyze)

;;; ---------- collector ----------

(struct collected (color-ranges defs jumps) #:mutable)
;; color-ranges : (listof (list span symbol))
;; defs         : (listof (list span symbol))
;; jumps        : (listof (list span symbol path))

(define (make-collector src)
  (define st (collected '() '() '()))
  (define collector%
    (class (annotations-mixin object%)
      (super-new)
      ;; 让 traversal 认「这就是当前文件的 defs-text」，否则 def/jump 回调不触发
      (define/override (syncheck:find-source-object stx)
        (and (equal? src (syntax-source stx)) src))
      (define/override (syncheck:color-range _src start finish style)
        (when (< start finish)
          (set-collected-color-ranges!
           st (cons (list (span start finish)
                          (if (string? style) (string->symbol style) style))
                    (collected-color-ranges st)))))
      (define/override (syncheck:add-definition-target/phase-level+space
                        _src start finish id _mods _ph)
        (when (< start finish)
          (set-collected-defs! st (cons (list (span start finish) id) (collected-defs st)))))
      (define/override (syncheck:add-jump-to-definition/phase-level+space
                        _src start finish id filename _submods _ph)
        (when (< start finish)
          (set-collected-jumps! st (cons (list (span start finish) id filename)
                                         (collected-jumps st)))))))
  (values (new collector%) st))

;;; ---------- 主入口 ----------

(define (expand-analyze path text)
  (define path* (if (path? path) path (string->path path)))
  (with-handlers ([exn? (lambda (e) (failure path* text (exn-message e)))])
    (define-values (src-dir _n _m) (split-path path*))
    (define ns (make-base-namespace))
    (define-values (add-syntax done) (make-traversal ns src-dir))
    (define in (open-input-string text))
    (port-count-lines! in)
    (define-values (collector st) (make-collector path*))
    ;; 1) 读取
    (define stx
      (parameterize ([current-namespace ns]
                     [current-load-relative-directory src-dir]
                     [current-annotations collector])
        (with-handlers ([exn:fail? (lambda (e) e)])
          (with-module-reading-parameterization (lambda () (read-syntax path* in))))))
    (cond
      [(not (syntax? stx))
       (failure path* text (if (exn? stx) (exn-message stx) "读取失败"))]
      [else
       ;; 2) 展开
       (define expanded
         (parameterize ([current-namespace ns]
                        [current-load-relative-directory src-dir]
                        [current-annotations collector])
           (with-handlers ([exn:fail? (lambda (e) e)])
             (parameterize ([current-output-port (open-output-nowhere)])
               (expand stx)))))
       (cond
         [(not (syntax? expanded))
          (failure path* text (if (exn? expanded) (exn-message expanded) "展开失败"))]
         [else
          ;; 3) 注解遍历
          (parameterize ([current-namespace ns]
                         [current-load-relative-directory src-dir]
                         [current-annotations collector])
            (add-syntax expanded)
            (done))
          (build-result path* text st)])])))

;;; ---------- 汇总 ----------

(define (build-result path text st)
  (define color-ranges (remove-duplicates (reverse (collected-color-ranges st))))
  (define defs (remove-duplicates (reverse (collected-defs st))))
  (define jumps (remove-duplicates (reverse (collected-jumps st))))
  (define def-spans (map car defs))
  (define (name-of sp) (string->symbol (substring text (span-start sp) (span-end sp))))
  (define (variable-style? s)
    (memq s '(drracket:check-syntax:lexically-bound drracket:check-syntax:set!d)))

  (define sem-vars
    (for/list ([cr (in-list color-ranges)] #:when (variable-style? (cadr cr)))
      (sem-token (car cr) 'variable '())))
  (define sem-defs
    (for/list ([d (in-list defs)])
      (sem-token (car d) 'variable '(definition))))
  (define uses-local
    (for/list ([cr (in-list color-ranges)]
               #:when (and (variable-style? (cadr cr)) (not (member (car cr) def-spans))))
      (occurrence (car cr) (name-of (car cr)) path)))
  (define uses-imported
    (for/list ([u (in-list jumps)] #:when (path? (caddr u)))
      (occurrence (car u) (cadr u) (caddr u))))

  (expand-result path
                 (merge-sem-tokens (append sem-vars sem-defs))
                 (for/list ([d (in-list defs)]) (definition (car d) (cadr d) path))
                 (append uses-local uses-imported)
                 '()))

;; 同区间合并：type 取 variable，modifiers 求并（定义点 = variable + definition）。
(define (merge-sem-tokens toks)
  (define ordered (sort toks < #:key (lambda (t) (span-start (sem-token-span t)))))
  (define groups
    (group-by (lambda (t) (list (span-start (sem-token-span t)) (span-end (sem-token-span t))))
              ordered))
  (for/list ([g (in-list groups)])
    (sem-token (sem-token-span (car g))
               'variable
               (remove-duplicates (append* (map sem-token-modifiers g))))))

(define (failure path text msg)
  (expand-result path '() '() '()
                 (list (diagnostic (span 0 (string-length text)) 'error msg))))
