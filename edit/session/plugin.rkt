#lang racket

;;; edit/session/plugin.rkt —— document 插件绑定 / 状态 / 写回（会话侧）
;;;
;;; 绑定：打开文件时由规则层把「适用插件集」按 did 记进来（session.plugin-bindings）。
;;; 状态：每个 did 的插件 state 放在**文档槽** plugin-state 里，随版本 fork：
;;;   · 槽值 = (path plugins entries dirty written?)；entries = hash 插件名 -> (cons state fills)；
;;;   · 首次（槽 #f）在渲染前 open 整篇；
;;;   · 之后每次编辑 fork：用本次编辑的**脏行**调各插件的 change，只重算脏行
;;;     （fills 只覆盖 dirty），待重绘行累积到渲染前一次写回；
;;;   · undo 恢复旧 document 即得当时那一版的槽（含 face 端口）→ 无需重算。
;;; 写回：渲染前对「有插件、且本版本还没写回」的文档，清脏行 face 再按 fills 合成。
;;;   · fork 里累积「上次未写回的行 ∪ 本次脏行」，保证一次渲染覆盖所有待更新行；
;;;   · 写回后把 dirty 清空、written? 置真 → 同版本后续帧跳过。
;;; 槽注册（define-document-slot）必须早于任何 document 创建；本模块经 session.rkt
;;; 在装配前加载，满足该约束。

(require racket/list
         racket/match
         "value.rkt"
         "doc.rkt"
         "core.rkt"
         "../plugin/registry.rkt"
         "../core/lex.rkt")

(provide session-doc-plugins session-doc-bind-plugins
         session-doc-plugin-forget
         session-doc-plugins-apply
         plugin-state)

;;; ---------- 绑定（纯） ----------

(define (session-doc-plugins s did) (hash-ref (session-plugin-bindings s) did '()))
(define (session-doc-bind-plugins s did ps)
  (struct-copy session s [plugin-bindings (hash-set (session-plugin-bindings s) did ps)]))

;; 关文档时清掉该 did 的绑定（槽随 document 版本回收，无需清理）。
(define (session-doc-plugin-forget s did)
  (struct-copy session s
    [plugin-bindings (hash-remove (session-plugin-bindings s) did)]))

;;; ---------- 状态槽 ----------

(struct plugin-slot (path plugins entries dirty written?) #:transparent)
;; path    : path
;; plugins : (listof doc-plugin)   适用集（首次建槽时定，版本间不变）
;; entries : (hash 插件名 -> (cons state (listof fill)))   fills 只覆盖 dirty 各行
;; dirty   : (listof exact-integer)   待重绘的行（升序去重）
;; written? : boolean                 本版本 face 是否已写回

(define (dedupe-sorted ns) (sort (remove-duplicates ns) <))

;; 本次编辑的脏行（升序去重；edits 为编辑后坐标的 (l0 c0 l1 c1)）。
(define (edits->dirty-lines edits)
  (define h (make-hash))
  (for ([e (in-list edits)])
    (match-define (list l0 _c0 l1 _c1) e)
    (for ([l (in-range l0 (add1 l1))]) (hash-set! h l #t)))
  (sort (hash-keys h) <))

;; 活动词（本次编辑插入点前一个字符所在的词）→ (list line start end) | #f。
;; 领域逻辑（词法）留在插件侧；core 边界只给中性的 edits / 行文本。
(define (edits->active ctx edits)
  (cond
    [(not (= 1 (length edits))) #f]
    [else
     (match-define (list _l0 _c0 l1 c1) (car edits))
     (define col (sub1 c1))
     (cond
       [(< col 0) #f]
       [else
        (define line (for/first ([p (in-list (fork-ctx-lines ctx (list l1)))]) (cdr p)))
        (cond
          [(or (not line) (>= col (string-length line))) #f]
          [else (define tok (word-token-at line col))
                (and tok (list l1 (car tok) (cdr tok)))])])]))

;; 首次整篇 open。
(define (slot-open path plugins text line-count)
  (define entries
    (for/hash ([p (in-list plugins)])
      (define-values (st fl) ((doc-plugin-open p) text path))
      (values (doc-plugin-name p) (cons st fl))))
  (plugin-slot path plugins entries (for/list ([i (in-range line-count)]) i) #f))

;; fork：用本次编辑的脏行推进各插件状态（只算脏行）；累积待重绘行，written? 置假。
(define (plugin-slot-fork old ctx)
  (cond
    [(not old) #f]
    [else
     (define path (plugin-slot-path old))
     (define plugins (plugin-slot-plugins old))
     (define edits (fork-ctx-edits ctx))
     (define dirty (dedupe-sorted (append (plugin-slot-dirty old) (edits->dirty-lines edits))))
     (define lines (fork-ctx-lines ctx dirty))
     (define active (edits->active ctx edits))
     (define entries
       (for/hash ([p (in-list plugins)])
         (define name (doc-plugin-name p))
         (define o (hash-ref (plugin-slot-entries old) name (cons #f '())))
         (define-values (st fl) ((doc-plugin-change p) (car o) lines active path))
         (values name (cons st fl))))
     (plugin-slot path plugins entries (map car lines) #f)]))

(define-document-slot plugin-state #:default #f #:fork (transform plugin-slot-fork))

;;; ---------- 渲染前写回 ----------

(define (slot-fills sl)
  (append* (for/list ([p (in-list (plugin-slot-plugins sl))])
             (cdr (hash-ref (plugin-slot-entries sl) (doc-plugin-name p))))))

(define (session-doc-plugins-apply s)
  (for/fold ([s s]) ([did (in-list (session-document-ids s))])
    (define path (session-file-path s did))
    (cond
      [(not path) s]
      [else
       (define sl0 (session-doc-slot-ref s did plugin-state))
       (cond
         [(and sl0 (plugin-slot-written? sl0)) s]
         [else
          (define ps (if sl0 (plugin-slot-plugins sl0) (session-doc-plugins s did)))
          (cond
            [(null? ps)
             (if sl0
                 (session-doc-slot-set! s did plugin-state
                                        (struct-copy plugin-slot sl0 [written? #t] [dirty '()]))
                 s)]
            [else
             (define sl (or sl0
                            (slot-open path ps (session-document-string s did)
                                       (session-document-line-count s did))))
             (define s1 (session-doc-face-refill! s did (plugin-slot-dirty sl) (slot-fills sl)))
             (session-doc-slot-set! s1 did plugin-state
                                    (struct-copy plugin-slot sl [written? #t] [dirty '()]))])])])))
