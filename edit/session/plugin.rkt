#lang racket

;;; edit/session/plugin.rkt —— document 插件绑定 / 状态 / 写回（会话侧）
;;;
;;; 绑定：打开文件时由规则层把「适用插件集」按 did 记进来（session.plugin-bindings）。
;;; 状态：每个 did 的插件 state + 「行 → fills」映射放在**文档槽** plugin-state 里，随版本 fork：
;;;   · 槽值 = (path plugins entries dirty written?)；
;;;     entries = hash 插件名 -> (cons state (hash line -> (listof fill)))；
;;;   · 首次（槽 #f）在渲染前 open 整篇（fills 按行入表）；
;;;   · 每次编辑 fork：给各插件一个 change-ctx（脏行 / 编辑 / 活动词 / 取行）；
;;;     插件回 (state touched fills)；只把 touched 行的 fills 换进该插件的表；
;;;   · 待重画行 = 上次未写回行 ∪ 本次各插件的 touched；undo 恢复旧 document 即得旧槽。
;;; 写回：渲染前对「有插件、且本版本还没写回」的文档，清待重画行的 face，
;;;       再按**所有插件**在这些行的 fills 逐格 face-compose
;;;       （所以宽区域插件重画不会抹掉同行别的插件的贡献）。
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
;; entries : (hash 插件名 -> (cons state (hash line -> (listof fill))))
;; dirty   : (listof exact-integer)   待重画行（升序去重）
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

;; fills → hash line -> fills（保序）。
(define (bucket-by-line fills)
  (define h (make-hash))
  (for ([f (in-list fills)]) (hash-set! h (car f) (cons f (hash-ref h (car f) '()))))
  (for ([(k v) (in-hash h)]) (hash-set! h k (reverse v)))
  h)

;; 首次整篇 open。
(define (slot-open path plugins text line-count)
  (define entries
    (for/hash ([p (in-list plugins)])
      (define-values (st fl) ((doc-plugin-open p) text path))
      (values (doc-plugin-name p) (cons st (bucket-by-line fl)))))
  (plugin-slot path plugins entries (for/list ([i (in-range line-count)]) i) #f))

;; fork：给各插件 change-ctx，收集 touched 并更新「行→fills」表；accumulate 待重画行。
(define (plugin-slot-fork old ctx)
  (cond
    [(not old) #f]
    [else
     (define path (plugin-slot-path old))
     (define plugins (plugin-slot-plugins old))
     (define edits (fork-ctx-edits ctx))
     (define dirty-in (dedupe-sorted (edits->dirty-lines edits)))
     (define cctx (change-ctx (fork-ctx-lines ctx dirty-in) edits (edits->active ctx edits)
                              (lambda (n) (fork-ctx-line ctx n)) (fork-ctx-line-count ctx) path))
     (define touched-all '())
     (define entries
       (for/hash ([p (in-list plugins)])
         (define name (doc-plugin-name p))
         (define e (hash-ref (plugin-slot-entries old) name (cons #f (hash))))
         (define-values (st* touched fills) ((doc-plugin-change p) (car e) cctx))
         (set! touched-all (append touched-all touched))
         (define m (hash-copy (cdr e)))          ; 新版本新表，旧版本不动
         (for ([l (in-list touched)])
           (hash-set! m l (for/list ([f (in-list fills)] #:when (= (car f) l)) f)))
         (values name (cons st* m))))
     (define dirty (dedupe-sorted (append (plugin-slot-dirty old) touched-all)))
     (plugin-slot path plugins entries dirty #f)]))

(define-document-slot plugin-state #:default #f #:fork (transform plugin-slot-fork))

;;; ---------- 渲染前写回 ----------

;; 给定待重画行，取所有插件在这些行的 fills。
(define (slot-fills sl lines)
  (append*
   (for/list ([l (in-list lines)])
     (append*
      (for/list ([p (in-list (plugin-slot-plugins sl))])
        (hash-ref (cdr (hash-ref (plugin-slot-entries sl) (doc-plugin-name p))) l '()))))))

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
             (define n (session-document-line-count s did))
             (define sl (or sl0
                            (slot-open path ps (session-document-string s did) n)))
             (define dirty (for/list ([l (in-list (plugin-slot-dirty sl))] #:when (< l n)) l))
             (define s1 (session-doc-face-refill! s did dirty (slot-fills sl dirty)))
             (session-doc-slot-set! s1 did plugin-state
                                    (struct-copy plugin-slot sl [written? #t] [dirty '()]))])])])))
