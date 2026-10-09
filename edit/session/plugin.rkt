#lang racket

;;; edit/session/plugin.rkt —— document 插件绑定 / 状态 / 写回（会话侧，lab 式）
;;;
;;; 绑定：打开文件时由规则层把「适用插件集」按 did 记进来（session.plugin-bindings）。
;;; 状态：每个 did 的插件 state + **整篇 fills** 放进文档槽 plugin-state，随版本 fork：
;;;   · 槽值 = (path plugins entries written?)；entries = hash 插件名 -> (cons state fills)；
;;;   · 首次（槽 #f）在渲染前 open 整篇；
;;;   · 每次编辑 fork：给各插件 change-ctx，插件推进 state 并回**整篇 fills**；
;;;   · undo 恢复旧 document 即得旧 state（槽随版本回收）。
;;; 写回：渲染前对「有插件、且本版本还没写回」的文档，**清空整条 face 轨道**再叠加全部 fills。
;;;   · 因为 fills 永远是新文本的整篇，行号平移 / 行数变化都不会错（对齐 lab）。
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

(struct plugin-slot (path plugins entries written?) #:transparent);; path    : path
;; plugins : (listof doc-plugin)   适用集（首次建槽时定，版本间不变）
;; entries : (hash 插件名 -> (cons state (listof fill)))   fills = 整篇
;; written? : boolean              本版本 face 是否已写回

;; 活动词（本次编辑插入点前一个字符所在的词）→ (list line start end) | #f。
;; 领域逻辑（词法）留在插件侧；core 边界只给中性的 edits / 行文本。
(define (edits->active edits lines)
  (cond
    [(not (= 1 (length edits))) #f]
    [else
     (match-define (list _l0 _c0 l1 c1) (car edits))
     (define col (sub1 c1))
     (cond
       [(or (< col 0) (>= l1 (vector-length lines))) #f]
       [else
        (define line (vector-ref lines l1))
        (cond
          [(>= col (string-length line)) #f]
          [else (define tok (word-token-at line col))
                (and tok (list l1 (car tok) (cdr tok)))])])]))

;; 首次整篇 open。
(define (slot-open path plugins text)
  (define entries
    (for/hash ([p (in-list plugins)])
      (define-values (st fl) ((doc-plugin-open p) text path))
      (values (doc-plugin-name p) (cons st fl))))
  (plugin-slot path plugins entries #f))

;; fork：给各插件 change-ctx，推进 state 并取回整篇 fills；written? 置假。
(define (plugin-slot-fork old ctx)
  (cond
    [(not old) #f]
    [else
     (define path (plugin-slot-path old))
     (define plugins (plugin-slot-plugins old))
     (define edits (fork-ctx-edits ctx))
     (define lines (fork-ctx-lines ctx))
     (define cctx (change-ctx edits (edits->active edits lines) lines path))
     (define entries
       (for/hash ([p (in-list plugins)])
         (define name (doc-plugin-name p))
         (define o (hash-ref (plugin-slot-entries old) name (cons #f '())))
         (define-values (st fl) ((doc-plugin-change p) (car o) cctx))
         (values name (cons st fl))))
     (plugin-slot path plugins entries #f)]))

(define-document-slot plugin-state #:default #f #:fork (transform plugin-slot-fork))

;;; ---------- 渲染前写回 ----------

;; 各插件整篇 fills，按目录顺序拼接。
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
                 (session-doc-slot-set! s did plugin-state (struct-copy plugin-slot sl0 [written? #t]))
                 s)]
            [else
             (define sl (or sl0 (slot-open path ps (session-document-string s did))))
             (define s1 (session-doc-face! s did (slot-fills sl)))
             (session-doc-slot-set! s1 did plugin-state
                                    (struct-copy plugin-slot sl [written? #t]))])])])))
