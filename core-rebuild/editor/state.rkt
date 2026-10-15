#lang racket

;;; editor/state.rkt —— buffer / view 对象 + 结构手术
;;;
;;;   buffer = 一份内容 + 历史 + 共享它的所有 view      （身份 = 对象本身）
;;;   view   = 一块显示状态（viewport + selections），指回它的 buffer（身份 = 对象本身）
;;;
;;; 宿主持有这些对象；core 不集中管理多个文档，也没有 id。
;;; 对象可以不纯：字段用 #:mutable（结构手术 / 编辑就地写）。
;;;
;;; 可变数据结构定义在 state-data.rkt（core 内部）；这里对外**只导出访问器**，
;;; 用 except-out 裁掉裸 setter，写回 buffer/view 只能走 ops.rkt 的提交壳。

(require "state-data.rkt"
         "history.rkt"
         "../text/document.rkt"
         "../text/base/track.rkt"
         "../text/base/point.rkt"
         "../text/base/selection.rkt"
         "../view/base/viewport.rkt")

(provide
 ;; ---------- 类型（访问器 / 谓词 / 构造器；不含 setter） ----------
 (except-out (struct-out buffer)  ; name / history / views
             set-buffer-name! set-buffer-history! set-buffer-views!)
 (except-out (struct-out view)    ; buffer / viewport / selections
             set-view-buffer! set-view-viewport! set-view-selections!)

 ;; ---------- 构造 ----------
 make-buffer                       ; text [name] → buffer
 buffer-add-view!                  ; buffer [w h] → view（登记进 buffer.views；尺寸可选，panel 才是真相）
 buffer-close-view!                ; buffer view → 摘掉该 view
 buffer-close!                     ; buffer → 解除与所有 view 的关联

 ;; ---------- buffer 读 / 写 ----------
 buffer-document                   ; buffer → 当前 document
 buffer-set-name!                  ; buffer name → void

 ;; ---------- view 读 / 写 ----------
 view-document                     ; view → 当前 document（buffer→history→current）

 ;; ---------- 多态入口：string | document → document ----------
 ->document)                       ; x chunk-lines → document

;;; ---------- 多态入口 ----------

(define (->document x chunk-lines)
  (if (document? x) x (document-open x chunk-lines)))

;;; ---------- 构造 ----------

(define default-name "*scratch*")

;; 文首光标。
(define (initial-selections) (selections-one (caret (point 0 0))))

(define (make-buffer text [name default-name]
                     #:chunk-lines [chunk-lines default-chunk-lines]
                     #:history-limit [history-limit default-history-limit]
                     #:history? [history? #t])
  (buffer name
          (history-open (->document text chunk-lines) history-limit history?)
          '()))

;; 建一个视图挂到 buffer 上；返回新 view。
;; 尺寸是可选的：panel 才是尺寸真相（panel.rect → panels-sync!），这里只是初始占位。
(define (buffer-add-view! b [width 1] [height 1]
                          #:mode [mode 'clip]
                          #:line-numbers? [line-numbers? #f]
                          #:selections [sels (initial-selections)])
  (define v (view b (viewport-open width height mode line-numbers?) sels))
  (set-buffer-views! b (append (buffer-views b) (list v)))
  v)

;; 摘掉一个视图（不删 buffer）。
(define (buffer-close-view! b v)
  (set-buffer-views! b
    (for/list ([x (in-list (buffer-views b))] #:unless (eq? x v)) x)))

;; 关掉一个 buffer：解除与所有 view 的关联（对象本身由宿主丢引用后回收）。
(define (buffer-close! b)
  (set-buffer-views! b '()))

;;; ---------- buffer 读 / 写 ----------

(define (buffer-document b) (history-document (buffer-history b)))
(define (buffer-set-name! b n) (set-buffer-name! b n))

;;; ---------- view 读 / 写 ----------

(define (view-document v) (buffer-document (view-buffer v)))
