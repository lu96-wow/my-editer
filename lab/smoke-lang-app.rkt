#lang racket

;;; lab-rebuild/smoke-lang-app.rkt —— 语言服务集成（无终端）
;;; 验证：补全进入 / 过滤 / 接受，文档查询进浮窗、Enter 关闭。

(require rackunit
         racket/file
         racket/path
         racket/string
         "../core/editor.rkt"
         "../core/view/base/screen.rkt"
         "app/app.rkt"
         "app/render.rkt"
         "base/input.rkt"
         "base/layout/main.rkt"
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

;; 文档查询是后台 place 异步做的：轮询 tick 直到选中项文档回来（或超时）。
(define (wait-doc! a)
  (let loop ([n 0])
    (app-complete-tick! a)
    (cond [(and (complete? (app-mode a)) (complete-doc (app-mode a))) (void)]
          [(> n 500) (void)]
          [else (sleep 0.01) (loop (add1 n))])))

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
;; 选中项带 bluebox 文档（后台异步取，等一下）；菜单 + 文档在同一个实线框 pane 里
(wait-doc! a)
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

;;; ---------- 自动补全：输入即触发（无需 Tab，且不阻塞输入） ----------

;; 另开一个文件，避免干扰上面的状态。
(define code2 (build-path root "auto.rkt"))
(with-output-to-file code2 #:exists 'replace
  (lambda () (display "#lang racket/base\n(require racket/list)\n(add-\n")))
(app-open-path! a code2)
(define vid2 (app-edit-active a))
(set-app-focus! a vid2)
(editor-view-set-point! (ed) vid2 (point 2 5))          ; "add-" 之后

;; 打一个字符 → 弹层自动出现（不需要先按 Tab）。
(send (key-event #\b no-mods))
(check-not-false (complete? (app-mode a)))
(check-not-false (member "add-between" (complete-candidates (app-mode a))))
;; 自动路径也取文档（后台异步，等一下）。
(wait-doc! a)
(check-not-false (complete-doc (app-mode a)))
;; 继续打字：字符照常进文档（不阻塞输入），前缀跟着变。
(send (key-event #\e no-mods))
(check-true (complete? (app-mode a)))
(check-not-false (string-contains? (editor-view-string (ed) vid2) "(add-be"))

;; 上下选择不退出弹层。
(send (key-event 'down no-mods))
(check-not-false (complete? (app-mode a)))
(send (key-event 'up no-mods))
(check-not-false (complete? (app-mode a)))

;; Esc 取消：只关弹层，已输入文本保留。
(send (key-event 'escape no-mods))
(check-false (app-mode a))
(check-not-false (string-contains? (editor-view-string (ed) vid2) "(add-be"))

;; 再次打字重新触发，Enter 接受候选。
(send (key-event #\t no-mods))
(check-not-false (complete? (app-mode a)))
(send (key-event 'enter no-mods))
(check-false (app-mode a))
(check-not-false (string-contains? (editor-view-string (ed) vid2) "(add-between"))

;; 普通字符照常插入并关掉弹层（不阻塞输入）。
(send (key-event #\) no-mods))
(check-false (app-mode a))
(check-not-false (string-contains? (editor-view-string (ed) vid2) "(add-between)"))
;; 渲染整帧不崩
(check-not-false (screen? (app-render a)))

;;; ---------- 补全弹层位置：贴近光标且不遮挡输入行 ----------

;; 光标屏幕行（与 app/render.rkt 的 anchor-screen-pos 同算法）。
(define (anchor-row a vid)
  (define ed (app-ed a))
  (define p (editor-view-point ed vid))
  (define rect (for/first ([r (in-list (layout-result-panes (app-layout-result a)))]
                           #:when (eqv? (rectangle-view-id r) vid)) r))
  (define-values (row _col) (editor-view-point->screen-position ed vid p))
  (+ (rectangle-y rect) row))

;; 断言：弹层在屏内，且整块不压住光标所在输入行（下侧或上侧皆可）。
(define (check-popup-clear! a vid)
  (define arow (anchor-row a vid))
  (define p (car (app-complete-panes a)))
  (define prow (pane-row p))
  (define ph (screen-height (pane-screen p)))
  (check-true (and (>= prow 0) (<= (+ prow ph) (app-height a))))
  (check-true (or (> prow arow) (<= (+ prow ph) arow)))
  (values arow prow ph))

;; 光标在顶部：弹层放输入行下侧。
(define code3 (build-path root "top.rkt"))
(with-output-to-file code3 #:exists 'replace
  (lambda () (display "#lang racket/base\n(require racket/list)\n(add-\n")))
(app-open-path! a code3)
(define vid3 (app-edit-active a))
(set-app-focus! a vid3)
(editor-view-set-point! (ed) vid3 (point 2 5))
(send (key-event #\b no-mods))
(check-not-false (complete? (app-mode a)))
(define-values (arow3 prow3 _ph3) (check-popup-clear! a vid3))
(check-equal? prow3 (add1 arow3))                        ; 下侧：顶边贴光标行下一行
(send (key-event 'escape no-mods))

;; 光标贴近视口底部（长文件末尾）：弹层应翻到输入行上侧。
(define code4 (build-path root "bottom.rkt"))
(with-output-to-file code4 #:exists 'replace
  (lambda ()
    (display "#lang racket/base\n")
    (for ([i (in-range 40)]) (display (format "(define v~a ~a)\n" i i)))
    (display "add-\n")))
(app-open-path! a code4)
(define vid4 (app-edit-active a))
(set-app-focus! a vid4)
(editor-view-set-point! (ed) vid4 (point 41 4))          ; 最后一行 "add-" 末尾
(send (key-event #\b no-mods))
(check-not-false (complete? (app-mode a)))
(define-values (arow4 prow4 ph4) (check-popup-clear! a vid4))
(check-true (<= (+ prow4 ph4) arow4))                    ; 整块在光标行上方
(check-equal? (+ prow4 ph4) arow4)                       ; 底边贴光标行
(send (key-event 'escape no-mods))

;; 文档浮窗（C-p d）用同一条规则：光标贴底时翻到上侧，不遮输入行。
(editor-view-set-point! (ed) vid4 (point 41 2))          ; "add-" 中间
(send (key-event 'p (mods #t #f #f)))
(send (key-event #\d no-mods))
(check-not-false (docs? (app-mode a)))
(define docs-p
  (for/first ([p (in-list (app-overlay-panes a))] #:when (eq? (pane-id p) 'docs)) p))
(check-not-false docs-p)
(define darow (anchor-row a vid4))
(define drow (pane-row docs-p))
(define dh (screen-height (pane-screen docs-p)))
(check-true (or (> drow darow) (<= (+ drow dh) darow)))
(check-true (<= (+ drow dh) darow))                      ; 贴底 → 上侧
(send (key-event 'escape no-mods))
(check-false (app-mode a))

;;; ---------- 滚轮把光标滚出视口：浮层不崩、暂时不画 ----------

(editor-view-set-point! (ed) vid4 (point 41 4))          ; 末尾 "add-"
(send (key-event #\b no-mods))
(check-not-false (complete? (app-mode a)))
(editor-view-scroll! (ed) vid4 -30)                       ; 光标滚出视口
(check-equal? (app-complete-panes a) '())                 ; 没地方贴 → 先不画
(check-not-false (screen? (app-render a)))                ; 渲染不崩
(send (key-event 'escape no-mods))

;; 文档浮窗同理
(editor-view-set-point! (ed) vid4 (point 41 2))
(send (key-event 'p (mods #t #f #f)))
(send (key-event #\d no-mods))
(check-not-false (docs? (app-mode a)))
(editor-view-scroll! (ed) vid4 -30)
(check-equal? (for/list ([p (in-list (app-overlay-panes a))] #:when (eq? (pane-id p) 'docs)) p) '())
(check-not-false (screen? (app-render a)))
(send (key-event 'escape no-mods))
