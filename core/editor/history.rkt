#lang racket

;;; editor/history.rkt —— 撤销 / 重做（快照栈：每步存前态 + 后态）
;;;
;;; 一步 = 前态 ⊕ 后态，各含 document + selections + 发起者 who + 合并标签 merge-tag。
;;; 撤销 = 把 current 换成 past 的上一份**前态**；重做 = 换回**后态**。
;;; document 是持久化值，快照结构共享，所以「存整份文档」并不贵。
;;;
;;; **history 是哑栈**：history-record 一次就是一步，自己不做判断；
;;; history-merge 是把新后态**折叠**进当前步的原语（保留较早前态 / 当前 who 与 merge-tag）；
;;; history-seal 是把当前步**封口**的原语（只把 merge-tag 清成 #f，不新增步、不改文档）。
;;; 「什么时候并 / 什么时候封口」由 editor 层决定（见 editor/command.rkt）。
;;;
;;; 为什么一步要前后两份：多个视图共享一个文档时，撤销要把选区还原到**发起那次编辑的
;;; 视图**（who）。只存一份「当前快照」的话，前态里的选区会属于上一个编辑者。
;;;
;;;   past    当前之前的**前态**快照，越靠前越新
;;;   current 当前快照（最后一步的后态）
;;;   future  可重做的快照，越靠前越近
;;;   limit   past 长度上限
;;;   enabled? 是否记步（#f = 关闭：编辑只推进 current，不新增步）
;;;
;;; 关闭记步时（widget / 程序改写）：保留 past、清 future、把 current 的 merge-tag 封掉，
;;; 避免重开后与旧步合并或 redo 覆盖；undo/redo 在关闭期间一律 no-op。
;;;
;;; highlight / readonly 这类作者态不产生独立步：属性存放在 document 的 box 里，
;;; **就地**修改，再用 history-set-current 同步 current（document/who/selections），
;;; 于是随快照搭车回退。异步写回直接改 box 句柄，不经过这里（见 editor/attributes.rkt）。

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
;; who        : any/c（发起者身份；**不透明**，editor 传 view id）
;; merge-tag  : any/c（合并标签；**不透明载荷**，只有当前步的那份被 editor 读）
;;
;; 一步要带发起视图的 selections：多视图共享文档时，撤销要把光标还原到**发起那次编辑
;; 的视图**（who）。history 现在就在 editor 层，所以「存视图态」是同层行为；它只依赖
;; 文本层的 document/selections 值，不反向依赖 view 结构（who 只是个载荷）。

;;; ---------- 历史 ----------

;; enabled? : bool   是否记步（#f = 编辑只推进 current，不记步、不可 undo/redo）

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

;; 当前 document（单一事实源：live 文档就存在 current 快照里，不另存一份）。
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

;; 记一步：pre = 编辑前（doc + sels），post = 编辑后。**永远新起一步**，并清空 redo。
;; merge-tag 只是随步存下的不透明载荷。enabled? = #f 时不记步（只推进 current）。
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

;; 折叠：把 post 并进**当前步**（保留较早的前态、当前的 who / merge-tag），并清空 redo。
;; 只在调用方已判定「可并」时用（见 editor/command.rkt）；哑栈不做判断。
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

;; 开关记步（只改一个字段，不破坏结构）。
(define (history-set-enabled h on?)
  (struct-copy history h [enabled? (and on? #t)]))

;; 封口：只把当前步的 merge-tag 清成 #f（**不新增步、不改文档、不动 redo**）。
;; 之后即使同 tag 的编辑也接不上——这就是一「段」的终点。
(define (history-seal h)
  (struct-copy history h
    [current (struct-copy snapshot (history-current h) [merge-tag #f])]))

;; 改 current 的 document / selections / who（不记步、不动 merge-tag）。
;; 用于 readonly / highlight 这类「随设随删」的作者态：
;;   · 不改 merge-tag —— 作者态**既不并进**打字段、也**不打断**它（连续性由选区决定）。
;;   · who 必须和新的 selections **一起**换：snapshot 的 (who, selections) 是
;;     「发起该步的视图 ⊕ 它当时的选区」这一对，拆开改会让 undo→redo 把
;;     别的视图的选区还到 who 上（cross-view 作者态的经典 bug）。
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
