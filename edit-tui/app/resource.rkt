#lang racket

;;; app/resource.rkt —— 资源管理：document / view 的创建、绑定、替换
;;;
;;; “打开 / 创建 document+view”是 app 的核心动作：
;;;
;;;   · document（buffer）是数据真身，view 是它在某个 panel 里的显示；
;;;   · 创建时给 document 绑类型（kind），类型决定命令表（doc-kind.rkt）；
;;;   · 布局是 panel 容器，view 可随时用 view-into（= tree-set-view）替换进某个 leaf。
;;;
;;; 本模块是**唯一造 core 对象的地方**（不纯）。world 仍是纯数据，所以：
;;;   · 启动装配：直接调用 open-document! 拿 (values buffer view)，再放进 tree；
;;;   · 运行期打开：命令返回 open-doc intent（见 intent.rkt），由 loop 的解释器
;;;     调本模块创建，再用 intent 里的纯变换把 view 装进布局 —— step 不碰不纯。
;;;
;;; 暂定：resources 只登记 buffer 列表（够用于查找 / 遍历 / 以后关闭）。

(require "../../core/editor.rkt"
         "../layout/main.rkt"
         "doc-kind.rkt")

(provide make-resources resources? resources-list resource-register!
         make-document open-document!
         view-into)

;;; ════════════════════════ 已打开资源登记 ════════════════════════

(struct resources (docs) #:transparent #:mutable)
;; docs : (listof buffer)（新打开的在前）

(define (make-resources) (resources '()))
(define (resource-register! res b)
  (set-resources-docs! res (cons b (resources-docs res)))
  b)
(define (resources-list res) (resources-docs res))

;;; ════════════════════════ 造 document + view ════════════════════════

;; 创建 buffer + view 并绑类型。不登记、不做别的事。
(define (make-document name text #:kind [kind 'text] #:line-numbers? [ln? #f])
  (define b (make-buffer text name))
  (define v (buffer-add-view! b #:line-numbers? ln?))
  (buffer-set-kind! b kind)
  (values b v))

;; 创建并登记。启动装配常用。
(define (open-document! res name text #:kind [kind 'text] #:line-numbers? [ln? #f])
  (define-values (b v) (make-document name text #:kind kind #:line-numbers? ln?))
  (resource-register! res b)
  (values b v))

;;; ════════════════════════ 布局装配（纯） ════════════════════════

;; 把 view 替换进布局树的某个 leaf（core 的 tree-set-view，纯）。
(define (view-into tree leaf-id view)
  (tree-set-view tree leaf-id view))
