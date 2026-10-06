#lang racket

;;; lab-rebuild/smoke-lang.rkt —— 补全 / 文档包冒烟
;;;
;;; 验证：打字自动弹补全、接受候选改文本；C-p d 开文档浮窗、异步结果装回、关闭。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "app/app.rkt"
         "builtin/edit.rkt"
         "builtin/complete.rkt"
         "builtin/docs.rkt"
         "builtin/lang/source.rkt"
         "builtin/lang/complete.rkt"
         "builtin/lang/docs.rkt"
         "platform/state.rkt"
         "platform/mode.rkt"
         "platform/input.rkt")

;;; ---------- 纯层回归（顺带） ----------

(check-equal? (source-requires "#lang racket\n(require \"\")") '(racket))
(check-not-false (member "add-between" (completions "add-" #:modules '(racket/list))))

;;; ---------- app ----------

(define root (simplify-path (path->complete-path (make-temporary-file "lg~a" 'directory))))
(define f (build-path root "code.rkt"))
(with-output-to-file f #:exists 'replace
  (lambda () (display "#lang racket/base\n(require racket/list)\n(add-\n")))

(define a (app-init root 100 30))
(define (send e) (app-handle-input a e))
(define (ed) (app-ed a))
(app-open-path! a f)
(define vid (app-focus a))

;;; ---------- 打字自动补全 ----------

(editor-view-set-point! (ed) vid (point 2 5))          ; "add-" 之后
(send (key-event #\b no-mods))                          ; 打字触发 after-insert
(check-true (complete? (app-mode a)))
(check-not-false (member "add-between" (complete-candidates (app-mode a))))
;; 菜单内嵌文档：等异步 bluebox 回来
(define (wait-complete-doc!)
  (let loop ([n 0])
    (app-job-tick! a)
    (define m (app-mode a))
    (cond [(and (complete? m) (complete-doc m)) (void)]
          [(> n 800) (void)]
          [else (sleep 0.01) (loop (add1 n))])))
(wait-complete-doc!)
(check-not-false (complete-doc (app-mode a)))
(check-true (string-contains? (doc-signature (complete-doc (app-mode a))) "add-between"))
(check-not-false (screen? (app-render a)))              ; 菜单 + 文档框不崩
;; 继续打字：前缀变、菜单跟着变（不阻塞输入）
(send (key-event #\e no-mods))
(check-true (string-contains? (editor-view-string (ed) vid) "(add-be"))
;; Enter 接受
(send (key-event 'enter no-mods))
(check-false (app-mode a))
(check-true (string-contains? (editor-view-string (ed) vid) "(add-between"))
;; 渲染含补全浮层时不崩
(check-not-false (screen? (app-render a)))

;;; ---------- 显式补全触发（C-n）+ 取消；Tab = 两个空格 ----------

(editor-view-set-point! (ed) vid (point 2 (string-length "(add-between")))
(send (key-event 'n (mods #t #f #f)))                    ; C-n 显式补全
(check-true (complete? (app-mode a)))
(send (key-event 'escape no-mods))
(check-false (app-mode a))

;; Tab 普通输入 = 两个空格（不再弹补全）
(define len-before (string-length (editor-view-string (ed) vid)))
(send (key-event 'tab no-mods))
(check-equal? (string-length (editor-view-string (ed) vid)) (+ len-before 2))
(check-false (app-mode a))

;; 空前缀（光标不在词上）C-n → 不弹、不拉全量
(send (key-event 'enter no-mods))                        ; newline-and-indent → 新行
(send (key-event 'n (mods #t #f #f)))
(check-false (app-mode a))

;;; ---------- 文档浮窗（异步） ----------

;; 文件里放一个可查的标识符
(editor-view-set-point! (ed) vid (point 2 4))           ; "add-between" 中间
(define before (app-focus a))
(send (key-event 'p (mods #t #f #f)))                   ; C-p
(send (key-event #\d no-mods))                          ; d = show-docs
(check-true (docs? (app-mode a)))
(check-equal? (app-focus a) before)                     ; 浮窗不动焦点

;; 等异步文档结果（place）
(define (wait-docs!)
  (let loop ([n 0])
    (app-job-tick! a)
    (define m (app-mode a))
    (cond [(and (docs? m) (not (docs-pending m))) (void)]
          [(> n 800) (void)]
          [else (sleep 0.01) (loop (add1 n))])))
(wait-docs!)
(define docs-text (string-join (vector->list (docs-lines (app-mode a))) "\n"))
(check-true (string-contains? docs-text "add-between"))
;; 渲染不崩，然后关闭
(check-not-false (screen? (app-render a)))
(send (key-event 'escape no-mods))
(check-false (app-mode a))

(displayln "lang smoke: ok")
