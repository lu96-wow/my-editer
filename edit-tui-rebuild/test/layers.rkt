#lang racket

;;; 分层约束的可执行版本：
;;;
;;; 依赖方向只能「上层 -> 下层」。这里读各模块的 require 列表做断言，
;;; 比文档更早发现反向依赖 / 纯层里混进副作用。
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

;; 模块的 require 目标（只取字符串路径）
(define (requires rel)
  (append*
   (for/list ([f (in-list (read-forms rel))]
              #:when (and (list? f) (eq? (car f) 'require)))
     (append* (for/list ([spec (in-list (cdr f))]) (all-strings spec))))))

(define (requires-any? rel pattern)
  (for/or ([r (in-list (requires rel))])
    (regexp-match? pattern r)))

;;; ---------- 值 / 词汇层：不依赖 app / runtime / 渲染 ----------
(for ([m (in-list '("base/api.rkt" "face/model.rkt" "panel/model.rkt"
                    "command/key.rkt" "command/table.rkt" "config/model.rkt"))])
  (check-false (requires-any? m #rx"(^|/)(app|runtime|projection|render)/") m))

;;; ---------- layout：tree <- solve <- ops 单向 ----------
(check-false (requires-any? "layout/tree.rkt" #rx"(^|/)(solve|ops)\\.rkt$"))
(check-false (requires-any? "layout/solve.rkt" #rx"(^|/)ops\\.rkt$"))
(check-true (requires-any? "layout/solve.rkt" #rx"(^|/)tree\\.rkt$"))
(check-true (requires-any? "layout/ops.rkt" #rx"(^|/)(tree|solve)\\.rkt$"))
(check-false (requires-any? "layout/tree.rkt" #rx"(^|/)(app|runtime|projection|render)/"))

;;; ---------- resource：纯，不依赖 app / runtime ----------
(check-false (requires-any? "resource/model.rkt" #rx"(^|/)(app|runtime)/"))

;;; ---------- edit：model 纯；commands 只借 app/state，不碰 step/runtime ----------
(check-false (requires-any? "edit/model.rkt" #rx"(^|/)(app|runtime)/"))
(check-false (requires-any? "edit/commands.rkt" #rx"(^|/)(runtime|step\\.rkt)"))
(check-false (requires-any? "edit/commands.rkt" #rx"(^|/)step\\.rkt$"))

;;; ---------- filetree：lines 是纯投影（不许 require IO）；panel 才做同步 ----------
(check-false (requires-any? "filetree/lines.rkt" #rx"(^|/)scan\\.rkt$"))
(check-false (requires-any? "filetree/lines.rkt" #rx"(^|/)(runtime|engine)/"))
(check-true (requires-any? "filetree/scan.rkt" #rx"(^|/)racket/path"))
(check-false (requires-any? "filetree/model.rkt" #rx"(^|/)(app|runtime)/"))

;;; ---------- projection / render：纯，不依赖 app / runtime ----------
(check-false (requires-any? "projection/geometry.rkt" #rx"(^|/)(app|runtime)/"))
(check-true (requires-any? "projection/geometry.rkt" #rx"(^|/)borders\\.rkt$"))
(check-false (requires-any? "projection/borders.rkt" #rx"(^|/)(app|runtime|render)/"))
(check-false (requires-any? "render/layout.rkt" #rx"(^|/)(app|runtime)/"))

;;; ---------- app 基础层：state 只依赖布局 / 资源，不依赖功能 / runtime ----------
(check-false (requires-any? "app/state.rkt" #rx"(^|/)(chrome|edit|filetree|runtime|step)/"))
(check-false (requires-any? "app/state.rkt" #rx"(^|/)step\\.rkt$"))
;; step 是纯编排点：可以 require 功能模块，但绝不 require runtime
(check-false (requires-any? "app/step.rkt" #rx"(^|/)runtime/"))

;;; ---------- 功能模块之间：不互相 require（只共享 edit 的导航表） ----------
(check-false (requires-any? "chrome/input.rkt" #rx"(^|/)(filetree|edit)/"))
(check-false (requires-any? "filetree/commands.rkt" #rx"(^|/)(chrome)/"))

(displayln "edit-tui-rebuild/test/layers.rkt: ok")
