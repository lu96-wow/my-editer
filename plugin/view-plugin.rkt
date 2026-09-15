#lang racket

(require "../core/view/window.rkt" "../core/text/buffer.rkt" "../core/text/cursor.rkt" rackunit)

;;; slot.rkt —— 插件 slot：每个「数据派生位置」= 一组同类型纯函数 + 一个组合器。
;;;
;;; 与 buffer 插件（buffer→buffer，吃 dirty，见 plugin.rkt）不同，本文件给出
;;; 「视口派生」slot：
;;;   view 插件 : window → (listof status-seg)
;;;   组合器    : run-view-plugins —— 按序执行，把各插件的状态段拼成一条状态行。
;;;
;;; 所有 slot 的通用约定：
;;;   - 插件是纯函数：输入该层状态数据，输出该层派生数据（不修改输入）
;;;   - 组合 = 顺序执行；拼接型派生数据用 append；变换型用 for/fold
;;;   - 空插件列表返回空（本 slot）或原样（buffer slot）

(provide
 (struct-out status-seg)
 run-view-plugins
 status-segs->string)

;; 状态段：一段文本 + 可选语义 face（渲染时映射成颜色/样式；#f = 无样式）。
(struct status-seg (text face) #:transparent)

;; view 插件 = (-> window (listof status-seg))
(define (run-view-plugins w vps)
  (apply append (for/list ([p (in-list vps)]) (p w))))

;; 把状态段拼成纯文本（无样式渲染用）。
(define (status-segs->string segs)
  (apply string-append (map status-seg-text segs)))

(module+ test
  (define b (buffer-open "hello\nworld"))
  (define w (window-open b 24 80))
  (define-values (w1 _1) (window-goto w 1 2))

  (define (rowcol w)
    (define p (window-point w))
    (list (status-seg (format "Ln ~a Col ~a" (add1 (cursor-line p)) (add1 (cursor-col p))) #f)))
  (define (mode w)
    (list (status-seg (symbol->string (window-mode w)) 'mode)))

  (check-equal? (status-segs->string (run-view-plugins w1 (list rowcol mode)))
                "Ln 2 Col 3clip")
  (check-equal? (run-view-plugins w1 '()) '())
  (check-equal? (status-segs->string '()) "")

  (displayln "slot.rkt: all tests passed"))
