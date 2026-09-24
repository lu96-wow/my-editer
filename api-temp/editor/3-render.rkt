#lang racket

;;; api-temp/editor/3-render.rkt —— 最终 API · 渲染（core/editor.rkt）
;;;
;;; 底层渲染（width / window / vrow / render-line / screen / window->screen / mirror）在 api-temp/api/3-render.rkt。
;;; 这里只讲 **editor 层** 的投影：从「编辑器」直接得到一帧 screen，以及位置 ↔ 屏幕坐标。
;;;
;;; 为什么有 editor 投影（而不是自己拿 window）：
;;;   · editor 知道 did/vid，能一步从 vid 找到它看的 window/document，省掉手动解析；
;;;   · provider 形状统一成 (editor did line) —— 与属性、语法高亮同一层，应用不必碰 buffer；
;;;   · screen 后端无关：同一帧可画终端 / GUI / Web（画字节是后端的事）。
;;;
;;; provider 形状（平台层）：editor did line → (listof (list start end face))。
;;;
;;; 运行：racket api-temp/editor/3-render.rkt

(require "../../core/editor.rkt"
         "../../core/api.rkt")     ; point / attr-set / read-only-key …

(define (show label v) (printf "~a\n    => ~v\n" label v))
(define (header s) (printf "\n========== ~a ==========\n" s))
(define (P l c) (point l c))
(define (row-strings scr) (for/list ([i (in-range (screen-height scr))]) (screen-row->string scr i)))

;;; ===========================================================================
(header "1. editor->screen / editor-view->screen")
;;; ===========================================================================

;; editor->screen : editor [provider] → screen（投**焦点 view**）
;; editor-view->screen : editor vid [provider] → screen（投指定 view）
;;   设计：把「哪个 view + 它的 window + provider」三件事一次做完，输出后端无关的 screen。
;;         文本 runs 与 光标/选区 overlay 是**两条独立通道**，后端分别画（overlay 叠加在上）。
;;   用法：每帧调用；焦点投屏用 editor->screen，多窗格各投自己的 vid。
(define e (editor-open "hello\nworld" 2 10 #:name "a"))
(show "(editor->screen e) 行文本" (row-strings (editor->screen e)))
(show "(editor-view->screen e 0) 行0" (screen-row (editor-view->screen e 0) 0))
(show "(editor->screen e) 光标" (screen-cursors (editor->screen e)))
;; 平台层缺省 provider：empty-face-provider : editor did line → '()
;;   设计：无派生 face 时返回空，core 不发明 face 值（未覆盖段渲染成 #f）。
(show "(empty-face-provider e 0 0)" (empty-face-provider e 0 0))
;; 视图装饰会进 screen：开行号栏 → 前缀 run face = 'line-number，正文右移。
;;   设计：行号是**视图装饰**（window 状态），不是文档文本，所以不拼进 buffer。
(show "(editor->screen 开行号) 行0"
      (screen-row (editor->screen (editor-set-line-numbers e #t)) 0))

;;; ===========================================================================
(header "2. attrs-provider —— 把属性 key 物化成 face-provider")
;;; ===========================================================================

;; attrs-provider : symbol → (editor did line → runs)
;;   设计：属性（作者态标注，如只读、拼写错误）存进文档、随编辑移动；
;;         投影时用一个 provider 把它读成 face 段。文档只存 key/value，不存颜色/样式。
;;   用法：face 语义由后端映射成颜色；同一个 key 可被不同后端解释成不同样式。
(define-values (ep _a1) (editor-document-put-attr (editor-open "hello") 0 'face 0 0 5 'bold))
(show "(editor->screen ep (attrs-provider 'face)) 行0"
      (screen-row (editor->screen ep (attrs-provider 'face)) 0))
;; 自定义 provider：纯函数、不进文档（如语法高亮）。
;;   设计：派生 face = content 的纯函数 → 不存、不失效、随投影现算，天然不会过期。
(define (highlight-provider _ed _did line)
  (if (zero? line) (list (list 0 5 (hash 'face 'keyword))) '()))
(show "(editor->screen ep highlight-provider) 行0"
      (screen-row (editor->screen ep highlight-provider) 0))
;; 两个来源可以拼接；同段时**列表里靠前的先命中**（render 取第一个覆盖的 run）。
;;   用法：作者态（属性）与派生（高亮）汇合时，用顺序表达优先级。
(define (both-provider ed did line)
  (append (highlight-provider ed did line) ((attrs-provider 'face) ed did line)))
(show "(拼接 provider，高亮在前) 行0" (screen-row (editor->screen ep both-provider) 0))

;;; ===========================================================================
(header "3. 位置 ↔ 屏幕坐标")
;;; ===========================================================================

;; editor-view-point->screen : editor vid → (values row col)（投该 view 的 primary 光标）
;; editor-point->screen      : editor → (values row col)（焦点 view）
;;   设计：point.col 是**字符索引**；屏幕 row/col 是**视觉坐标**（显示列，宽字符占 2；行号栏偏移已算入）。
;;         这层换算考虑 mode（clip/wrap）与滚动，应用不用自己算。
;;   用法：画硬件光标 / 悬浮 UI 定位；不可见时可能给 #f（api 层 window-point->screen 同）。
(show "(editor-view-point->screen e 0)" (call-with-values (lambda () (editor-view-point->screen e 0)) list))
(show "(editor-point->screen e)" (call-with-values (lambda () (editor-point->screen e)) list))
;; editor-view-screen->point : editor vid row col → (values line col)
;; editor-screen->point      : editor row col → (values line col)
;;   设计：逆映射——鼠标点击/命中测试用；落在行号栏会归到该行行首。
(show "(editor-view-screen->point e 0 1 2)" (call-with-values (lambda () (editor-view-screen->point e 0 1 2)) list))
(show "(editor-screen->point e 0 3)" (call-with-values (lambda () (editor-screen->point e 0 3)) list))
(show "(editor-point->screen (光标 1,2))" (call-with-values (lambda () (editor-point->screen (editor-set-point e (P 1 2)))) list))

(printf "\neditor/3-render.rkt 跑完（没有报错）。\n")
