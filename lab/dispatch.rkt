#lang racket

;;; dispatch.rkt —— 输入分发：keymap 栈 ⊕ stroke → intent（纯函数）
;;;
;;; 这是「每个文档独立键位」的解析处，也是瞬时模式的解析处。它只做三件事：
;;;   1) 从栈顶往下找第一张能处理该 stroke 的 keymap；
;;;   2) 按 keymap.rkt 的三层语义产出 intent（origin = 传入的 vid）；
;;;   3) 什么都不命中 → #f（忽略这次输入）。
;;;
;;; **纯**：不读 session、不改状态、不认识编辑器。调用方负责把 keymap 栈排好：
;;;     模式栈（瞬时，栈顶在前） ++ [焦点文档的 keymap] ++ [全局 keymap]
;;;
;;; 于是：
;;;   · 加文档类型 = 给它登记一张 keymap，不碰这里；
;;;   · 加瞬时模式 = 往栈里压一张（模态键位可 catch-all 全吞）；
;;;   · 换键 = 只改 bindings.rkt。

(provide dispatch)

(require "keymap.rkt" "key.rkt" "intent.rkt")

;; kms : (listof keymap)，栈顶在前；st : stroke；origin : vid | #f
;; → intent | #f
(define (dispatch kms st origin)
  (cond
    [(null? kms) #f]
    [else
     (define k (car kms))
     (define b (keymap-find k (stroke-token st)))
     (cond
       ;; 1) 精确命中
       [b (intent (binding-tag b) (binding-payload b) origin)]
       ;; 2) 文本兜底：默认绑定接收输入文本（并入 payload 末尾）
       [(and (keymap-default k) (text-stroke? st))
        (define d (keymap-default k))
        (intent (binding-tag d)
                (append (binding-payload d) (list (stroke-text st)))
                origin)]
       ;; 3) 模态：吞掉，不再往下
       [(keymap-catch-all? k) #f]
       ;; 4) 交给下一张
       [else (dispatch (cdr kms) st origin)])]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  ;; 一张"文档键位"：n 新建、↑↓ 导航、文本兜底 = 插入
  (define doc-km
    (km 'doc (list (list #\n 'tree/new) (list 'up 'nav/up) (list 'down 'nav/down))
        (bind 'editor/insert)))

  ;; 一张"模态"键位：回车确认、Esc 取消、文本兜底 = 提示输入，其余全吞
  (define modal-km
    (km 'modal (list (list 'enter 'prompt/confirm) (list 'escape 'prompt/cancel))
        (bind 'prompt/insert) #t))

  ;; 1) 精确 + 文本兜底
  (check-equal? (dispatch (list doc-km) (make-stroke #\n) 7)
                (intent 'tree/new '() 7))
  (check-equal? (dispatch (list doc-km) (make-stroke #\x) 7)
                (intent 'editor/insert '("x") 7))
  (check-equal? (dispatch (list doc-km) (make-stroke-text "abc") 7)
                (intent 'editor/insert '("abc") 7))

  ;; 2) 模态在栈顶：回车走确认；文本走提示；未绑定的 'up 被吞（不落给 doc-km）
  (check-equal? (dispatch (list modal-km doc-km) (make-stroke 'enter) 7)
                (intent 'prompt/confirm '() 7))
  (check-equal? (dispatch (list modal-km doc-km) (make-stroke #\y) 7)
                (intent 'prompt/insert '("y") 7))
  (check-false (dispatch (list modal-km doc-km) (make-stroke 'up) 7))   ; 模态吞掉

  ;; 3) 非模态且无兜底命中的键会往下落
  (define thin (km 'thin (list (list 'escape 'overlay/close))))         ; 无 default、无 catch-all
  (check-equal? (dispatch (list thin doc-km) (make-stroke #\n) 7)
                (intent 'tree/new '() 7))
  (check-equal? (dispatch (list thin doc-km) (make-stroke 'escape) 7)
                (intent 'overlay/close '() 7))

  ;; 4) 全部不命中 → #f
  (check-false (dispatch (list (km 'empty '())) (make-stroke 'up) 7))

  (displayln "lab/dispatch.rkt: all tests passed"))
