#lang racket

;;; 分层约束的可执行版本：
;;;
;;;   骨架（skeleton）  ← 插件（edit / chrome / filetree） ← app 编排 ← runtime
;;;
;;; 规则：
;;;   - 骨架不认识 app / 插件 / runtime；
;;;   - 插件只 require skeleton.rkt（不直接拿骨架实现模块 / core），
;;;     插件之间只经对方 api.rkt；可以 require app/state 等 app 基础；
;;;   - app/state、app/event、app/action 只 require 骨架；
;;;   - app/step 只 require 骨架 + app 基础 + 插件 api.rkt；
;;;   - runtime 可以 require 一切（它是唯一副作用层）。
(require rackunit
         racket/file
         racket/path
         racket/string)

(define test-dir (path->complete-path (find-system-path 'run-file)))
(define root (simplify-path (build-path (path-only test-dir) 'up)))

(define (read-forms rel)
  (define text (regexp-replace #rx"^#lang[^\n]*\n"
                               (file->string (build-path root rel))
                               ""))
  (with-input-from-string text
    (λ ()
      (let loop ([acc '()])
        (define x (read))
        (if (eof-object? x) (reverse acc) (loop (cons x acc)))))))

(define (all-strings x)
  (cond
    [(string? x) (list x)]
    [(symbol? x) (list (symbol->string x))]
    [(list? x) (append* (for/list ([e (in-list x)]) (all-strings e)))]
    [else '()]))

;; 模块的 require 目标（路径字符串 + 裸模块名）
(define (requires rel)
  (append*
   (for/list ([f (in-list (read-forms rel))]
              #:when (and (list? f) (eq? (car f) 'require)))
     (append* (for/list ([spec (in-list (cdr f))]) (all-strings spec))))))

(define (requires-any? rel pattern)
  (for/or ([r (in-list (requires rel))]) (regexp-match? pattern r)))

;; 骨架实现文件（插件不许直接拿）
(define skeleton-impl?
  #rx"(^|/)(base|command|config|face|panel|layout|focus|projection|render|resource|engine)/[^/]+\\.rkt$")
;; 插件的实现文件（跨插件只许 api.rkt）
(define plugin-impl?
  #rx"(^|/)(edit|chrome|filetree)/[^/]+\\.rkt$")
(define upper-layer? #rx"(^|/)(app|chrome|filetree|edit|runtime)/")
(define core-require? #rx"(^|/)core/")

;;; ════════════════ 骨架 ════════════════
(define skeleton-files
  '("base/api.rkt"
    "command/key.rkt" "command/table.rkt" "command/api.rkt"
    "config/model.rkt" "config/api.rkt"
    "face/model.rkt" "face/api.rkt"
    "panel/model.rkt" "panel/api.rkt"
    "layout/tree.rkt" "layout/solve.rkt" "layout/ops.rkt" "layout/api.rkt"
    "focus/model.rkt" "focus/api.rkt"
    "projection/borders.rkt" "projection/geometry.rkt" "projection/api.rkt"
    "render/theme.rkt" "render/core.rkt" "render/layout.rkt" "render/api.rkt"
    "resource/model.rkt" "resource/api.rkt"
    "engine/action.rkt" "engine/store.rkt" "engine/api.rkt"))

(for ([m (in-list skeleton-files)])
  (check-false (requires-any? m upper-layer?) m)
  (check-false (requires-any? m #rx"(^|/)skeleton/") m))

;; 骨架内部顺序
(check-false (requires-any? "layout/tree.rkt" #rx"(^|/)(solve|ops)\\.rkt$"))
(check-false (requires-any? "layout/solve.rkt" #rx"(^|/)ops\\.rkt$"))
(check-true (requires-any? "layout/solve.rkt" #rx"(^|/)tree\\.rkt$"))
(check-true (requires-any? "layout/ops.rkt" #rx"(^|/)(tree|solve)\\.rkt$"))
(check-true (requires-any? "projection/geometry.rkt" #rx"(^|/)borders\\.rkt$"))
; engine 不认识 app（action 词汇也在骨架里）
(check-false (requires-any? "engine/store.rkt" #rx"(^|/)app/"))

;; 骨架入口本身只聚合骨架 api
(check-false (requires-any? "skeleton.rkt" upper-layer?) "skeleton.rkt")
(check-false (requires-any? "skeleton.rkt" core-require?) "skeleton.rkt")

;;; ════════════════ 插件（edit / chrome / filetree） ════════════════
(define plugin-files
  '("edit/insert.rkt" "edit/commands.rkt" "edit/api.rkt"
    "chrome/status.rkt" "chrome/input.rkt" "chrome/api.rkt"
    "filetree/model.rkt" "filetree/lines.rkt" "filetree/scan.rkt"
    "filetree/slice.rkt" "filetree/sync.rkt" "filetree/commands.rkt"
    "filetree/api.rkt"))

(for ([m (in-list plugin-files)])
  ;; 不许摸 core / runtime / 骨架实现
  (check-false (requires-any? m core-require?) m)
  (check-false (requires-any? m #rx"(^|/)runtime/") m)
  (check-false (requires-any? m skeleton-impl?) m)
  ;; 骨架只经 skeleton.rkt
  (for ([r (in-list (requires m))]
        #:when (regexp-match? #rx"(^|/)skeleton\\.rkt$" r))
    (check-true (regexp-match? #rx"skeleton\\.rkt$" r) (format "~a -> ~a" m r)))
  ;; 跨插件只经对方 api.rkt
  (for ([r (in-list (requires m))]
        #:when (regexp-match? plugin-impl? r))
    (check-true (regexp-match? #rx"/api\\.rkt$" r) (format "~a -> ~a" m r))))

;; 插件组合骨架：至少用到 skeleton.rkt（api.rkt / 纯 model 例外）
(for ([m (in-list '("edit/commands.rkt" "chrome/status.rkt" "chrome/input.rkt"
                    "filetree/sync.rkt" "filetree/commands.rkt"))])
  (check-true (for/or ([r (in-list (requires m))])
                (regexp-match? #rx"skeleton\\.rkt$" r))
              m))

;; 纯投影 / 状态不碰 IO
(check-false (requires-any? "filetree/lines.rkt" #rx"(^|/)scan\\.rkt$"))
(check-false (requires-any? "filetree/model.rkt" upper-layer?))

;;; ════════════════ app 基础 / 编排 ════════════════
(for ([m (in-list '("app/state.rkt" "app/event.rkt" "app/action.rkt"
                    "app/placement.rkt" "app/step.rkt"))])
  (check-false (requires-any? m skeleton-impl?) m)
  (check-false (requires-any? m core-require?) m)
  (check-false (requires-any? m #rx"(^|/)runtime/") m)
  (for ([r (in-list (requires m))]
        #:when (regexp-match? plugin-impl? r))
    (check-true (regexp-match? #rx"/api\\.rkt$" r) (format "~a -> ~a" m r))))

;; app/state 只依赖骨架（+ 自己）
(check-false (requires-any? "app/state.rkt" #rx"(^|/)(chrome|edit|filetree)/"))
(check-false (requires-any? "app/state.rkt" #rx"(^|/)step\\.rkt$"))

;;; ════════════════ 入口 ════════════════
;; 顶层 api 只聚合 api.rkt（允许 */api.rkt，不许实现文件）
(define (impl-require? rel)
  (for/or ([r (in-list (requires rel))])
    (and (or (regexp-match? skeleton-impl? r)
             (regexp-match? plugin-impl? r))
         (not (regexp-match? #rx"api\\.rkt$" r)))))

;; main 是唯一聚合入口（没有顶层 api.rkt）
(check-false (impl-require? "main.rkt") "main.rkt")
(check-false (file-exists? (build-path root "api.rkt")) "顶层不应再有 api.rkt")

; 骨架 demo 也只走 main API
(check-false (requires-any? "demo/layout.rkt" core-require?) "demo/layout.rkt")

(displayln "edit-tui-rebuild/test/layers.rkt: ok")
