#lang racket
;;; 06 —— 属性写回：face / readonly / 开放槽
;;;
;;; 运行：racket temp/06-attributes.rkt
;;;
;;; 端口（port）：core 固定契约，语义/名字固定。
;;;   face       每字符一个 face，#f = 无       —— 渲染读
;;;   readonly   每字符一个布尔，#t = 不可写    —— 编辑守读
;;; 槽（slot）：特性声明的 opaque 存储，core 不懂语义，只做生命周期 / fork。
;;;
;;; 槽注册必须早于任何 document 创建（document-open 会 freeze-slots!）。
;;; 槽 API 属于「特性」体系，不在 buffer/view 使用层，故直接 require 实现模块。

(require "../core/editor.rkt"
         "../core/text/slot-dsl.rkt"
         (only-in "../core/editor/attributes.rkt" buffer-slot-set!)
         (only-in "../core/editor/query.rkt" buffer-slot-ref)
         (only-in "../core/editor/state.rkt" buffer-document)
         (only-in "../core/text/document.rkt" document-editable?))

;; 槽声明（必须在 make-buffer 之前）
(define-document-slot revision #:default 0 #:fork reset)
(define-document-slot note #:default "" #:fork reset)

(define b (make-buffer "hello\nworld"))
(define v (buffer-add-view! b 40 10))

(define (title s) (printf "\n==== ~a ====\n" s))

(title "face：按区间 / 格写")
(buffer-face-range! b (range-of (point 0 0) (point 0 5)) 'keyword)
(buffer-face-cell! b 1 2 'string)
(printf "face@(0,0)=~a (0,4)=~a (0,5)=~a (1,2)=~a (1,0)=~a\n"
        (buffer-face-at b 0 0) (buffer-face-at b 0 4)
        (buffer-face-at b 0 5) (buffer-face-at b 1 2) (buffer-face-at b 1 0))

(title "face：批量 runs = (list (list range face))")
(buffer-face-range-batch! b (list (list (range-of (point 1 0) (point 1 3)) 'comment)))
(printf "batch face@(1,0)=~a\n" (buffer-face-at b 1 0))

(title "readonly：按行写 + 读")
(buffer-readonly-line! b 0 #t)
(printf "readonly@(0,0)=~a (1,0)=~a\n"
        (buffer-readonly-at? b 0 0) (buffer-readonly-at? b 1 0))
(printf "document-editable? [0,0)-(0,3): ~a\n"
        (document-editable? (buffer-document b) 0 0 0 3))

(title "开放槽：写 / 读（通用句柄 API）")
(buffer-slot-set! b revision 42)
(buffer-slot-set! b note "draft")
(printf "revision=~a note=~s\n"
        (buffer-slot-ref b revision) (buffer-slot-ref b note))

(title "编辑后按策略 fork（reset -> 回默认）")
(view-set-point! v (point 1 5))
(void (buffer-edit! b v (op-type "!")))
(printf "revision=~a note=~s\n"
        (buffer-slot-ref b revision) (buffer-slot-ref b note))
