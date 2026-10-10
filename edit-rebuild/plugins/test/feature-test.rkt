#lang racket

;;; edit-rebuild/plugins/test/feature-test.rkt —— 停靠面插件（状态 / 输入行 / 日志）集成
;;;
;;;   raco test edit-rebuild/plugins/test/feature-test.rkt

(require rackunit
         "../../core/session/adapter.rkt"
         "../../core/session/session.rkt"
         "../../core/session/render.rkt"
         "../../core/session/panel.rkt"
         "../../core/session/bottom.rkt"
         "../../core/session/prompt.rkt"
         "../../core/extension/spec.rkt"
         "../../core/command/dispatch.rkt"
         "../../core/command/command.rkt"
         "../../core/command/key.rkt"
         "../ui/status.rkt"
         "../ui/prompt.rkt"
         "../ui/log.rkt"
         "../ui/ids.rkt")

(define s3 (install-plugins (session-blank 80 24)
                            (list status-spec prompt-spec log-spec)))
(define svid (session-panel-vid s3 panel-status))
(define ivid (session-panel-vid s3 panel-input))
(define lvid (session-panel-vid s3 panel-log))

;; 三个停靠面都登记了
(check-not-false svid)
(check-not-false ivid)
(check-not-false lvid)

;; 刷新：状态面 content 产出文档（无编辑视图 → " edit"）
(define s4 (session-prepare-render s3))
(check-equal? (session-view-string s4 svid) " edit")

;; 日志追加 → 刷新后出现在日志面；无 prompt 时自动弹出
(define s5 (session-log! s4 "hello"))
(check-equal? (session-log s5) '("hello"))
(check-true (session-visible? s5 lvid))
(define s6 (session-prepare-render s5))
(check-equal? (session-view-string s6 lvid) "hello")

;; 输入行：cmd-prompt-open → 打字 → Enter 提交 → 回调写日志
(define s7 (step s6 (cmd-prompt-open "go: " (lambda (s text) (session-log! s text)))))
(define s8 (dispatch s7 (input text-binding "hi" #f #f #f #f)))
(check-equal? (session-view-string s8 ivid) "go: hi")
(define s9 (dispatch s8 (input (key 'enter) #f #f #f #f #f)))
(check-false (session-prompt s9))
(check-equal? (session-log s9) '("hello" "hi"))
