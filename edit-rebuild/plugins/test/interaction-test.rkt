#lang racket

;;; plugins/test/interaction-test.rkt —— 键盘 / 鼠标交互（headless）
;;;
;;;   raco test plugins/test/interaction-test.rkt
;;;
;;; 覆盖：焦点在树时按键命中树的键表（不再被其它面板抢）、Enter 打开文件、
;;;       鼠标点击树聚焦并定位光标。

(require rackunit
         racket/string
         racket/file
         "../../core/app/app.rkt"
         "../../core/session/session.rkt"
         "../../core/session/adapter.rkt"
         "../../core/session/panel.rkt"
         "../../core/session/render.rkt"
         "../../core/session/prompt.rkt"
         "../../core/session/focus.rkt"
         "../../core/focus.rkt"
         "../../core/command/input.rkt"
         "../../core/command/engine.rkt"
         "../../core/command/key.rkt"
         "../../core/command/command.rkt"
         "../../core/path.rkt"
         "../catalog.rkt"
         "../ui/ids.rkt")

(define s (session-prepare-render (app-session 80 24 #:plugins enabled-plugins)))
(define tvid (session-panel-vid s panel-tree))
(check-not-false tvid)

;; 初始焦点在树
(check-equal? (session-focus-vid s) tvid)

;; Tab 不再换焦点；文档未显示 → 引擎无命中，返回原会话。
(check-eq? (engine-dispatch s (input (key 'tab) #f #f #f #f #f)) s)

;; 按键命中树的键表：down 移动树光标
(define s1 (engine-dispatch s (input (key 'down) #f #f #f #f #f)))
(check-equal? (session-view-point-line s1 tvid) 1)
(define s1b (engine-dispatch s1 (input (key 'down) #f #f #f #f #f)))
(check-equal? (session-view-point-line s1b tvid) 2)

;; 选中某一行并按 Enter 激活（目录展开 / 文件打开）
(define tlines (string-split (session-view-string s1b tvid) "\n"))
(define root-line 0)
(define s2 (engine-dispatch (session-ed-set-point! s1b tvid root-line 0)
                     (input (key 'enter) #f #f #f #f #f)))
;; 根目录 Enter = 收起/展开，不应崩
(check-not-false s2)

;; 找到一个文件的测试：用临时文件作为树根不方便，改为直接发 cmd-open-file-path
(define p (make-temporary-file "it-~a.rkt"))
(display-to-file "hi\n" p #:exists 'replace)
(define s3 (engine-dispatch s2 (input (key 'f 'ctrl) #f #f #f #f #f)))   ; cmd-open-file → 打开输入行
(check-true (prompt? (session-prompt s3)))
;; 输入行出现：底部区切到 input，状态行隐藏
(check-true (session-visible? s3 (session-panel-vid s3 panel-input)))
(check-false (session-visible? s3 (session-panel-vid s3 panel-status)))
;; 在输入行打路径并回车
(define s4 (engine-dispatch s3 (input text-binding (path->string p) #f #f #f #f)))
(define s5 (engine-dispatch s4 (input (key 'enter) #f #f #f #f #f)))
;; 提交后：底部区换回状态行（input 隐藏）
(check-false (prompt? (session-prompt s5)))
(check-false (session-visible? s5 (session-panel-vid s5 panel-input)))
(check-true (session-visible? s5 (session-panel-vid s5 panel-status)))
(define did (session-file-did s5 (normalize p)))
(check-not-false did)
(check-equal? (session-view-string s5 (session-edit-vid s5)) "hi\n")

;; C-p d：前缀 C-p 后接 d，经引擎命中前缀路由（无 docs 窗口时命令无操作），前缀被清掉。
(define sp (engine-dispatch s5 (input (key 'p 'ctrl) #f #f #f #f #f)))
(check-not-false (session-prefix sp))
(define s5d (engine-dispatch sp (input (key 'd) #f #f #f #f #f)))
(check-false (session-prefix s5d))

;; 取消（Escape）同样换回状态行
(define s5b (engine-dispatch s5 (input (key 'f 'ctrl) #f #f #f #f #f)))
(define s5c (engine-dispatch s5b (input (key 'escape) #f #f #f #f #f)))
(check-false (prompt? (session-prompt s5c)))
(check-true (session-visible? s5c (session-panel-vid s5c panel-status)))

;; 鼠标点击树：聚焦并定位
(define s6 (session-set-focus s5 (focus-set (session-focus s5) tvid)))
(define s7 (engine-dispatch s6 (input (mouse 'press 'left '()) #f #f #f 3 4)))
(check-equal? (session-focus-vid s7) tvid)
(check-equal? (session-view-point-line s7 tvid) 4)

(delete-file p)
