#lang racket

;;; editor/history.rkt —— 撤销 / 重做（快照栈：每步存前态 + 后态）
;;;
;;; 一步 = 前态 ⊕ 后态，各含 document + selections + 发起者 who + 合并标签 merge-tag。
;;; 撤销 = 把 current 换成 past 的上一份前态；重做 = 换回后态。
;;; document 是持久化值，快照结构共享。
;;;
;;; history-record 一次就是一步；history-merge 把新后态折叠进当前步（保留较早前态、
;;; 当前 who 与 merge-tag）；history-seal 把当前步的 merge-tag 清成 #f（不新增步、不改文档）。
;;; 什么时候并 / 什么时候封口由 editor 层决定（见 editor/command.rkt）。
;;;
;;; 一步存前后两份：多个视图共享一个文档时，撤销把选区还原到发起那次编辑的视图（who）。
;;;
;;;   past    当前之前的前态快照，越靠前越新
;;;   current 当前快照（最后一步的后态）
;;;   future  可重做的快照，越靠前越近
;;;   limit   past 长度上限
;;;   enabled? 是否记步（#f = 关闭：编辑只推进 current，不新增步）
;;;
;;; 关闭记步时（widget / 程序改写）：保留 past、清 future、把 current 的 merge-tag 封掉；
;;; undo/redo 是 no-op。
;;;
;;; highlight / readonly 这类作者态不产生独立步，也不经过这里：属性存放在 document 的
;;; box 里，就地修改。document 是 box 的持有者，同一 document 值的所有快照都看到新属性；
;;; undo/redo 只还原文本文档值，不还原属性（见 editor/attributes.rkt）。

(provide
 ;; ---------- 类型 ----------
 (struct-out snapshot)
 (struct-out history)

 ;; ---------- 构造 ----------
 history-open
 default-history-limit

 ;; ---------- 读 ----------
 history-state
 history-document
 history-can-undo? history-can-redo?
 history-depth

 ;; ---------- 写原语（哑栈，不做判断） ----------
 history-record
 history-merge
 history-seal
 history-set-current
 history-set-enabled

 ;; ---------- 撤销 / 重做 ----------
 history-undo
 history-redo
 history-clear)

;;; ---------- 快照 ----------

(struct snapshot (document selections who merge-tag) #:transparent)
;; document   : document    文本层值
;; selections : selections  发起视图当时的选区（**视图态**）
;; who        : any/c（发起者身份，editor 传 view id）
;; merge-tag  : any/c（合并标签）
;;
;; 一步带发起视图的 selections：撤销把光标还原到发起那次编辑的视图（who）。

;;; ---------- 历史 ----------

;; enabled? : bool   是否记步（#f = 编辑只推进 current）

(struct history (past current future limit enabled?) #:transparent)
;; past    : (listof snapshot)  前态，越靠前越新
;; current : snapshot           当前快照
;; future  : (listof snapshot)  可重做的快照，越靠前越近
;; limit   : nat                past 长度上限

(define default-history-limit 1000)

;; 新建：只有一份初始快照，没有可撤销 / 可重做的步。enabled? 默认 #t（普通文档）。
(define (history-open doc sels [limit default-history-limit] [enabled? #t])
  (history '() (snapshot doc sels #f #f) '() limit (and enabled? #t)))

;; 当前状态（document, selections, who）。
(define (history-state h)
  (define c (history-current h))
  (values (snapshot-document c) (snapshot-selections c) (snapshot-who c)))

;; 当前 document（live 文档存在 current 快照里）。
(define (history-document h) (snapshot-document (history-current h)))

(define (history-can-undo? h) (and (history-enabled? h) (pair? (history-past h))))
(define (history-can-redo? h) (and (history-enabled? h) (pair? (history-future h))))
(define (history-depth h) (length (history-past h)))

(define (trim-past past limit)
  (if (> (length past) limit) (take past limit) past))

;;; ---------- 写 ----------

;; 关了记步时的一次编辑：只推进 current（清 future、封 merge-tag），**保留 past**。
(define (history-record-off h post-doc post-sels who)
  (history (history-past h) (snapshot post-doc post-sels who #f) '() (history-limit h) #f))

;; 记一步：pre = 编辑前（doc + sels），post = 编辑后；新起一步并清空 redo。
;; merge-tag 随步存下。enabled? = #f 时不记步（只推进 current）。
(define (history-record h pre-doc pre-sels post-doc post-sels [who #f] [merge-tag #f])
  (cond
    [(not (history-enabled? h)) (history-record-off h post-doc post-sels who)]
    [else
     (history (trim-past (cons (snapshot pre-doc pre-sels who #f) (history-past h))
                         (history-limit h))
              (snapshot post-doc post-sels who merge-tag)
              '()
              (history-limit h)
              (history-enabled? h))]))

;; 折叠：把 post 并进当前步（保留较早的前态、当前的 who / merge-tag），并清空 redo。
;; 由调用方判定可并时用（见 editor/command.rkt）。
;; enabled? = #f 时同样不记步，只推进 current。
(define (history-merge h post-doc post-sels)
  (cond
    [(not (history-enabled? h))
     (history-record-off h post-doc post-sels (snapshot-who (history-current h)))]
    [else
     (struct-copy history h
       [current (struct-copy snapshot (history-current h)
                             [document post-doc] [selections post-sels])]
       [future '()])]))

;; 开关记步。
(define (history-set-enabled h on?)
  (struct-copy history h [enabled? (and on? #t)]))

;; 封口：把当前步的 merge-tag 清成 #f（不新增步、不改文档、不动 redo）。
;; 之后同 tag 的编辑也接不上。
(define (history-seal h)
  (struct-copy history h
    [current (struct-copy snapshot (history-current h) [merge-tag #f])]))

;; 改 current 的 document / selections / who（不记步、不动 merge-tag）。
;; 用于把一次内容写「装上」current（editor-view-install!）：
;;   · 不改 merge-tag —— 内容写既不并进也不打断它。
;;   · who 和新的 selections 一起换：snapshot 的 (who, selections) 是一对。
(define (history-set-current h doc sels who)
  (struct-copy history h
    [current (struct-copy snapshot (history-current h)
                          [document doc] [selections sels] [who who])]))

;;; ---------- 撤销 / 重做 ----------

;; 撤销：current 进 future，past 头部（前态）成为新 current。
(define (history-undo h)
  (cond
    [(not (history-enabled? h)) (values h #f)]
    [(null? (history-past h)) (values h #f)]
    [else
     (define cur (history-current h))
     (define past (history-past h))
     (values (history (cdr past) (car past) (cons cur (history-future h)) (history-limit h)
                      (history-enabled? h))
             #t)]))

;; 重做：current 进 past，future 头部（后态）成为新 current。
(define (history-redo h)
  (cond
    [(not (history-enabled? h)) (values h #f)]
    [(null? (history-future h)) (values h #f)]
    [else
     (define cur (history-current h))
     (define future (history-future h))
     (values (history (trim-past (cons cur (history-past h)) (history-limit h))
                      (car future)
                      (cdr future)
                      (history-limit h)
                      (history-enabled? h))
             #t)]))

;; 清掉可撤销 / 可重做，只留当前。
(define (history-clear h)
  (struct-copy history h [past '()] [future '()]))
