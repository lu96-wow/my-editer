#lang racket

;;; lab1/model/session.rkt —— 会话（lab1 的根）：core editor 值 + lab 侧 delta
;;;
;;; 分工：
;;;   core/editor.rkt   文本 / 属性 / 撤销 / 选区 / 视口 的**单一事实源**
;;;   session           core 没有的：每个文档的文件路径 + 焦点
;;;
;;; 原则：
;;;   · 一切按**身份**引用（did / vid），**不缓存 document / view 值**；
;;;   · document 与 view 生命周期独立：关 view 永不动 document；关 document 才级联其 view；
;;;   · 允许 0 个 view 的文档（打开但不显示）；
;;;   · 默认不打开任何 scratch 文档（session-new = 空 editor）。

(require "../../core/editor.rkt")

(provide
 ;; ---------- 类型 ----------
 (struct-out doc-meta)
 (struct-out session)

 ;; ---------- 构造 ----------
 session-new

 ;; ---------- 结构操作 ----------
 session-open-document
 session-new-view
 session-close-view
 session-close-document

 ;; ---------- 焦点 ----------
 session-focus
 session-active-view

 ;; ---------- 枚举 ----------
 session-document-ids
 session-view-ids

 ;; ---------- 文件路径（lab delta） ----------
 document-path
 document-set-path)

(define default-width 80)
(define default-height 24)

;; per-document delta：core 已持有文本 / 属性 / 撤销 / 选区 / 视口；
;; lab 只额外记一个文件路径（#f = 未落盘）。
(struct doc-meta (path) #:transparent)

;; session = core editor 值 ⊕ (hash did → doc-meta) ⊕ 焦点 vid（#f = 无）。
(struct session (editor meta active) #:transparent)

;;; ---------- 构造 ----------

;; 空会话：没有任何文档 / 视图。默认状态。
(define (session-new)
  (session (editor-blank) (hash) #f))

;;; ---------- 结构操作 ----------

;; 打开文档：core 建「文档 + 视图」。
;; content : string（现开纯文本）| document（原样装入，含属性轨）。
;; → (values session did vid)；焦点给新 vid。
(define (session-open-document s content [name "*scratch*"] [path #f]
                               #:history? [history? #t]
                               #:width [width default-width]
                               #:height [height default-height])
  (define-values (ed* did vid)
    (editor-add-document-view (session-editor s) content width height name #:history? history?))
  (values (session ed*
                   (hash-set (session-meta s) did (doc-meta path))
                   vid)
          did vid))

;; 给已有文档再加一个视图（多 view）。→ (values session vid)；焦点给新 vid。
(define (session-new-view s did
                          #:width [width default-width]
                          #:height [height default-height])
  (define-values (ed* vid) (editor-add-view (session-editor s) did width height))
  (values (session ed* (session-meta s) vid) vid))

;; 关视图：core 删这个视图，**不动文档**；焦点若正是它就回落。
(define (session-close-view s vid)
  (define ed (editor-close-view (session-editor s) vid))
  (session ed (session-meta s) (fallback (session-active s) vid ed)))

;; 关文档：core 级联关它的所有视图；lab 清路径 delta；焦点若被牵连则回落。
(define (session-close-document s did)
  (define ed (editor-close-document (session-editor s) did))
  (define a (session-active s))
  (session ed
           (hash-remove (session-meta s) did)
           (if (and a (view-exists? ed a)) a (first-view-id ed))))

;;; ---------- 焦点（lab 概念；core 不持焦点） ----------

(define (session-focus s vid) (session (session-editor s) (session-meta s) vid))

;; 焦点视图 → (values view vid)；无焦点 / 焦点失效 → #f。
(define (session-active-view s)
  (define a (session-active s))
  (and a (view-exists? (session-editor s) a) (values (editor-view-ref (session-editor s) a) a)))

;;; ---------- 枚举（顺序稳定：等于 core 的列表顺序） ----------

(define (session-document-ids s)
  (for/list ([e (in-list (editor-documents (session-editor s)))]) (document-entry-id e)))

(define (session-view-ids s)
  (for/list ([v (in-list (editor-views (session-editor s)))]) (view-id v)))

;;; ---------- 文件路径（lab delta） ----------

(define (document-path s did) (doc-meta-path (hash-ref (session-meta s) did)))
(define (document-set-path s did path)
  (session (session-editor s)
           (hash-set (session-meta s) did (doc-meta path))
           (session-active s)))

;;; ---------- 内部 ----------

(define (view-exists? ed vid)
  (for/or ([v (in-list (editor-views ed))]) (= vid (view-id v))))

(define (first-view-id ed)
  (define vs (editor-views ed))
  (and (pair? vs) (view-id (car vs))))

;; 关的是焦点视图 → 回落到第一个视图（无视图则 #f）；否则焦点不动。
(define (fallback a vid ed)
  (if (equal? a vid) (first-view-id ed) a))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  ;; 空会话
  (define s0 (session-new))
  (check-equal? (session-document-ids s0) '())
  (check-equal? (session-view-ids s0) '())
  (check-false (session-active s0))

  ;; 开文档：did/vid、路径 delta、焦点
  (define-values (s1 did1 vid1) (session-open-document s0 "abc" "d0" "/tmp/d0.txt"))
  (check-equal? (list did1 vid1) '(0 0))
  (check-equal? (session-document-ids s1) '(0))
  (check-equal? (session-view-ids s1) '(0))
  (check-equal? (session-active s1) 0)
  (check-equal? (document-path s1 did1) "/tmp/d0.txt")

  ;; 同一文档再加视图：文档不动，多一个 vid
  (define-values (s2 vid2) (session-new-view s1 did1))
  (check-equal? vid2 1)
  (check-equal? (session-view-ids s2) '(0 1))
  (check-equal? (session-document-ids s2) '(0))
  (check-equal? (session-active s2) 1)
  (check-equal? (editor-view-document-id (session-editor s2) 1) 0)

  ;; 关视图：文档还在，焦点回落
  (define s3 (session-close-view s2 vid2))
  (check-equal? (session-view-ids s3) '(0))
  (check-equal? (session-document-ids s3) '(0))
  (check-equal? (session-active s3) 0)

  ;; 第二个文档：路径互不干扰
  (define-values (s4 did4 vid4) (session-open-document s3 "xyz" "d1" "/tmp/d1.txt"))
  (check-equal? did4 1)
  (check-equal? (session-document-ids s4) '(0 1))
  (check-equal? (document-path s4 0) "/tmp/d0.txt")
  (check-equal? (document-path s4 1) "/tmp/d1.txt")

  ;; 0 个 view 的文档仍然存在（关视图 ≠ 关文档）
  (define s5 (session-close-view s4 vid4))
  (check-equal? (session-view-ids s5) '(0))
  (check-equal? (session-document-ids s5) '(0 1))
  (check-equal? (document-path s5 1) "/tmp/d1.txt")

  ;; 关文档：级联视图 + 清路径
  (define s6 (session-close-document s5 1))
  (check-equal? (session-document-ids s6) '(0))
  (check-exn exn:fail? (lambda () (document-path s6 1)))

  ;; 关最后一个文档 → 焦点 #f
  (define s7 (session-close-document s6 0))
  (check-equal? (session-document-ids s7) '())
  (check-false (session-active s7))

  ;; 程序生成文档：可关 history
  (define-values (s8 did8 _vid8) (session-open-document s7 "gen" "tree" #f #:history? #f))
  (check-false (editor-document-history-enabled? (session-editor s8) did8))

  (displayln "lab1/model/session.rkt: all tests passed"))
