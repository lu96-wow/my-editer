#lang racket

;;; lab-rebuild/kernel/effect.rkt —— 状态变换的描述（数据）。
;;;
;;; Effect 只描述"改什么"，不表达控制流；控制流在 policy/layer 层。
;;; kernel 的 apply-effect 是唯一施加点。

(provide (struct-out effect) fx
         ;; 编辑
         e-type e-backspace e-delete e-nav e-undo e-redo e-select-all
         e-copy e-cut e-paste e-move e-reload
         ;; 文档 / 视图
         e-show e-close e-save
         ;; 工作区
         e-focus e-focus-push e-sidebar
         e-split e-pane-close e-pane-swap e-pane-resize
         e-pointer e-scroll
         ;; 输入
         e-input-push e-input-pop e-input-set e-resume
         ;; 生命周期 / 会话
         e-notify e-quit e-session-size
         ;; 属性 / 异步闸门
         e-attr-highlight! e-await e-deliver)

(struct effect (tag args) #:transparent)
(define (fx tag . args) (effect tag args))

;; 编辑
(define (e-type vid text tag)      (fx 'type vid text tag))
(define (e-backspace vid tag)      (fx 'backspace vid tag))
(define (e-delete vid tag)         (fx 'delete vid tag))
(define (e-nav vid dir extend?)    (fx 'nav vid dir extend?))
(define (e-undo vid)               (fx 'undo vid))
(define (e-redo vid)               (fx 'redo vid))
(define (e-select-all vid)         (fx 'select-all vid))
(define (e-copy vid)               (fx 'copy vid))
(define (e-cut vid)                (fx 'cut vid))
(define (e-paste vid)              (fx 'paste vid))
(define (e-move vid sels)          (fx 'move vid sels))
(define (e-reload vid value)       (fx 'reload vid value))

;; 文档 / 视图：show 接受 path（现开）或 did；placement = 'replace | (list 'split dir)
(define (e-show id placement focus?) (fx 'show id placement focus?))
(define (e-close ids)              (fx 'close ids))
(define (e-save did)               (fx 'save did))

;; 工作区
(define (e-split dir)              (fx 'split dir))
(define (e-pane-close)             (fx 'pane-close))
(define (e-pane-swap dir)          (fx 'pane-swap dir))
(define (e-pane-resize dir)        (fx 'pane-resize dir))
(define (e-pointer vid row col)    (fx 'pointer vid row col))
(define (e-scroll vid delta)       (fx 'scroll vid delta))
(define (e-focus target)           (fx 'focus target))
(define (e-focus-push target)      (fx 'focus-push target))
(define (e-sidebar v)              (fx 'sidebar v))

;; 输入
(define (e-input-push spec-id state) (fx 'input (list 'push spec-id state)))
(define (e-input-pop spec-id)        (fx 'input (list 'pop spec-id)))
(define (e-input-set spec-id state)  (fx 'input (list 'set spec-id state)))
(define (e-resume sid response)      (fx 'resume sid response))

;; 生命周期 / 会话
(define (e-notify hook args)       (fx 'notify hook args))
(define (e-quit)                   (fx 'quit))
(define (e-session-size w h)       (fx 'session-size w h))

;; 属性写回（高亮轨）：先清空、再分层合成 fills；O(1)，不进 history。
(define (e-attr-highlight! did fills combine) (fx 'attr-highlight did fills combine))

;; 登记一个带版本闸门的异步挂起（结果由特性传输回灌 pipeline-deliver!）。
(define (e-await id version current? on-result) (fx 'await id version current? on-result))
(define (e-deliver id result) (fx 'deliver id result))
