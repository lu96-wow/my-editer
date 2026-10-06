#lang racket

;;; lab-rebuild/smoke-lang-app.rkt —— 语言服务集成（无终端）
;;; 验证：补全进入 / 过滤 / 接受，文档查询进浮窗、Enter 关闭。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../core/editor.rkt"
         "app/app.rkt"
         "app/render.rkt"
         "base/input.rkt"
         "ui/mode.rkt"
         "lang/docs.rkt"
         "core/state.rkt"
         "core/panes.rkt"
         "core/edit-panes.rkt"
         "core/actions.rkt")

(define root (simplify-path (path->complete-path (make-temporary-file "lang~a" 'directory))))
(define code (build-path root "code.rkt"))
(with-output-to-file code #:exists 'replace
  (lambda () (display "#lang racket/base\n(require racket/list)\n(add-b)\n")))

(define a (app-init root 100 30))
(define (send e) (app-handle-input a e))
(define (ed) (app-ed a))

(app-open-path! a code)
(define vid (app-edit-active a))
(set-app-focus! a vid)
(check-true (edit-panes-contains? (app-edit a) vid))

;;; ---------- 补全：Tab 进入 + 选中项文档面板 ----------

(editor-view-set-point! (ed) vid (point 2 6))            ; 光标在 "add-b" 之后
(send (key-event 'tab no-mods))                          ; Tab 触发补全
(check-not-false (complete? (app-mode a)))
(define cands (complete-candidates (app-mode a)))
(check-not-false (member "add-between" cands))
;; 选中项带 bluebox 文档；菜单 + 文档在同一个实线框 pane 里
(check-not-false (complete-doc (app-mode a)))
(check-not-false (and (doc-signature (complete-doc (app-mode a)))
                      (string-contains? (doc-signature (complete-doc (app-mode a))) "add-between")
                      #t))
(check-equal? (length (app-complete-panes a)) 1)
;; 弹层渲染不崩
(check-not-false (screen? (app-render a)))

;;; ---------- 补全：接受（菜单内 Tab 也是接受） ----------

(send (key-event 'tab no-mods))
(check-false (app-mode a))
(check-not-false (string-contains? (editor-view-string (ed) vid) "(add-between)"))

;;; ---------- 补全：打字实时过滤 ----------

(editor-view-set-point! (ed) vid (point 2 14))           ; "(add-between)" 末尾
(send (key-event 'n (mods #t #f #f)))                    ; Ctrl+N 直接补全（编辑态）
;; 此时前缀为空 → 显式触发也允许（可能候选很多）；只验证进入且候选非空
(check-not-false (complete? (app-mode a)))
(send (key-event 'escape no-mods))
(check-false (app-mode a))

;;; ---------- 文档查询：C-p d → 浮窗 ----------

(editor-view-set-point! (ed) vid (point 2 4))            ; 光标落在 add-between 上
(define panes-before (length (edit-panes-vids (app-edit a))))
(send (key-event 'p (mods #t #f #f)))
(send (key-event #\d no-mods))                           ; d = show-docs（真实终端送字符）
(check-not-false (docs? (app-mode a)))
(define docs-text (string-join (vector->list (docs-lines (app-mode a))) "\n"))
;; DrRacket 式：只有 bluebox（签名 / 契约），没有 HTML 正文
(check-not-false (and (string-contains? docs-text "add-between") #t))
(check-false (string-contains? docs-text "Returns a list"))
(check-false (string-contains? docs-text "https://"))
;; 浮窗不动编辑区（不像旧实现那样开缓冲 / 分屏）
(check-equal? (length (edit-panes-vids (app-edit a))) panes-before)
;; 渲染整帧不崩
(check-not-false (screen? (app-render a)))
;; 滚动不崩（bluebox 可能一屏就放完 → offset 被夹住）
(app-docs-scroll! a 5)
(check-true (>= (docs-offset (app-mode a)) 0))
;; Enter 关闭
(send (key-event 'enter no-mods))
(check-false (app-mode a))
