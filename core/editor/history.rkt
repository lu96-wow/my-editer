#lang racket

;;; editor/history.rkt —— 撤销 / 重做（纯文档版本栈）
;;;
;;; history 只保存「文档版本」这一条轴：
;;;
;;;   past    当前之前的文档版本，越靠前越新
;;;   current 当前文档真身（buffer 的 document 就取这里）
;;;   future  可重做的文档版本，越靠前越近
;;;
;;; 撤销 = current 在版本序列上前后移动（持久化 document 值，结构共享）；
;;; 选区合法性由调用方 clamp 保证。
;;;
;;; 并步（merge）不在本层判定：本层只提供 record / merge 两个原语，
;;; 由会话层（editor/ops.rkt 的提交壳）决定何时折叠、何时封口。

(provide
 ;; ---------- 类型 ----------
 (struct-out history)              ; 历史值：past / current / future / limit / enabled?

 ;; ---------- 构造 ----------
 history-open                      ; document [limit] [enabled?] → history
 default-history-limit             ; past 长度上限默认值

 ;; ---------- 读 ----------
 history-document                  ; history → 当前 document
 history-can-undo?                 ; history → bool
 history-can-redo?                 ; history → bool
 history-depth                     ; history → past 步数
 history-undo-target               ; history → 即将恢复的 document | #f（past 头）
 history-redo-target               ; history → 可重做的 document | #f（future 头）

 ;; ---------- 写原语（哑栈，不做判断） ----------
 history-record                    ; pre-doc post-doc → 新起一步（清 redo）
 history-merge                     ; post-doc → 折叠进当前步
 history-set-current               ; doc → 只推进 current（不记步）
 history-set-enabled               ; on? → 开关记步

 ;; ---------- 撤销 / 重做 ----------
 history-undo                      ; history → (values history ok?)
 history-redo                      ; history → (values history ok?)
 history-clear)                    ; 清 past / future，留 current

;;; ---------- 历史 ----------

(struct history (past current future limit enabled?) #:transparent)
;; past    : (listof document)   前态，越靠前越新
;; current : document            当前文档真身
;; future  : (listof document)   可重做，越靠前越近
;; limit   : nat                 past 长度上限
;; enabled? : bool               是否记步（#f = 编辑只推进 current）

(define default-history-limit 1000)

;; 新建：只有一份初始文档，没有可撤销 / 可重做的步。
(define (history-open doc [limit default-history-limit] [enabled? #t])
  (history '() doc '() limit (and enabled? #t)))

;; 当前文档。
(define (history-document h) (history-current h))

(define (history-can-undo? h) (and (history-enabled? h) (pair? (history-past h))))
(define (history-can-redo? h) (and (history-enabled? h) (pair? (history-future h))))
(define (history-depth h) (length (history-past h)))

;; 预览：撤销 / 重做将要恢复的文档（无 → #f）。只读，不推进栈。
(define (history-undo-target h)
  (and (history-enabled? h) (pair? (history-past h)) (car (history-past h))))
(define (history-redo-target h)
  (and (history-enabled? h) (pair? (history-future h)) (car (history-future h))))

(define (trim-past past limit)
  (if (> (length past) limit) (take past limit) past))

;;; ---------- 写 ----------

;; 关了记步时的一次编辑：只推进 current，清 future，**保留 past**。
(define (history-set-current-off h doc)
  (history (history-past h) doc '() (history-limit h) #f))

;; 记一步：pre = 编辑前的 document，post = 编辑后的 document；新起一步并清空 redo。
;; enabled? = #f 时不记步（只推进 current）。
(define (history-record h pre-doc post-doc)
  (cond
    [(not (history-enabled? h)) (history-set-current-off h post-doc)]
    [else
     (history (trim-past (cons pre-doc (history-past h)) (history-limit h))
              post-doc
              '()
              (history-limit h)
              (history-enabled? h))]))

;; 折叠：把 post 并进当前步（保留较早的前态），并清空 redo。
;; 由调用方判定可并时用（见 editor/ops.rkt 的 commit）。
(define (history-merge h post-doc)
  (cond
    [(not (history-enabled? h)) (history-set-current-off h post-doc)]
    [else
     (struct-copy history h [current post-doc] [future '()])]))

;; 改 current 的 document（不记步）。
;; 用于把一次内容写「装上」current（程序赋值 / 异步写回）。
(define (history-set-current h doc)
  (struct-copy history h [current doc]))

;; 开关记步。
(define (history-set-enabled h on?)
  (struct-copy history h [enabled? (and on? #t)]))

;;; ---------- 撤销 / 重做 ----------

;; 撤销：current 进 future，past 头部成为新 current。
(define (history-undo h)
  (cond
    [(not (history-enabled? h)) (values h #f)]
    [(null? (history-past h)) (values h #f)]
    [else
     (define cur (history-current h))
     (define past (history-past h))
     (values (history (cdr past) (car past) (cons cur (history-future h))
                      (history-limit h) (history-enabled? h))
             #t)]))

;; 重做：current 进 past，future 头部成为新 current。
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
