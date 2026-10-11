#lang racket

;;; edit-rebuild/core/session/plugin.rkt —— document face 插件绑定 / 状态 / 按行增量写回（会话侧）
;;;
;;; 绑定：打开文件时由规则层把「适用插件集」按 did 记进来（session.plugin-bindings）。
;;; 状态：每个 did 的插件 state + **层 track** 放进文档槽 plugin-state，随版本 fork：
;;;   · 槽值 = (path plugins entries dirty)；
;;;     entries = hash 插件名 -> (cons state layer)；
;;;   · 首次（槽 #f）在渲染前 open 整篇；
;;;   · 每次编辑 fork：给各插件 face-ctx（文本 / changes），插件推进 state/层并回**脏行**；
;;;   · 未渲染的多次编辑把脏行**求并**，写回一次做掉；
;;;   · undo 恢复旧 document 即得旧 state/层（槽随版本回收）。
;;; 写回：渲染前对每个文档调一次插件（changes 空、带光标），只清脏行再按插件顺序叠加各层。
;;;   · 光标移动不产生 change，但会经此让插件判定「正在输入的词」是否已编辑完；
;;;   · 行未变则由 track 结构共享，写回只碰脏行（O(脏行)）。
;;; 槽注册（define-document-slot）必须早于任何 document 创建；本模块经 session.rkt
;;; 在装配前加载，满足该约束。

(require "session.rkt"
         "adapter.rkt"
         "../document/rules.rkt"
         "../extension/face-plugin.rkt"
         "../face/line-scan.rkt"
         (only-in "../../../core/text/slots.rkt"
                  fork-ctx-changes fork-ctx-new-text fork-ctx-old-text)
         (only-in "../../../core/text/slot-dsl.rkt" define-document-slot))

(provide session-doc-plugins session-doc-bind-plugins
         session-doc-plugin-forget
         session-doc-plugins-apply
         plugin-state
         face-plugin-rule)

;;; ---------- 打开文件时的绑定规则 ----------

;; 一组 face 插件 → document rule（打开文件时按 path/text 挑适用插件记入 did）。
(define (face-plugin-rule plugins)
  (rule 'face-plugins
        (lambda (path) #t)
        (lambda (s did path)
          (session-doc-bind-plugins
           s did
           (plugins-for plugins path (session-document-string s did))))))

;;; ---------- 绑定（纯） ----------

(define (session-doc-plugins s did) (hash-ref (session-plugin-bindings s) did '()))
(define (session-doc-bind-plugins s did ps)
  (session-set-plugin-bindings s did ps))

;; 关文档时清掉该 did 的绑定（槽随 document 版本回收，无需清理）。
(define (session-doc-plugin-forget s did)
  (session-plugin-bindings-remove s did))

;;; ---------- 状态槽 ----------

(struct plugin-slot (path plugins entries dirty) #:transparent)
;; path     : path
;; plugins  : (listof face-plugin)   适用集（首次建槽时定，版本间不变）
;; entries  : (hash 插件名 -> (cons state layer))
;; dirty    : dirty                 上次写回以来累积的脏行

;; 首次整篇 open：建 state / 层，脏行 = 全篇。
(define (slot-open path plugins text)
  (define entries
    (for/hash ([p (in-list plugins)])
      (define-values (st ly) ((face-plugin-open p) text path))
      (values (face-plugin-name p) (cons st ly))))
  (plugin-slot path plugins entries (dirty-all)))

;; 推进一层：给各插件 face-ctx（changes + cursor），累积脏行。
(define (slot-advance old old-text new-text changes cursor)
  (cond
    [(not old) #f]
    [else
     (define path (plugin-slot-path old))
     (define plugins (plugin-slot-plugins old))
     (define cctx (face-ctx old-text new-text changes
                           (dirty-lines (changes->dirty-lines changes))
                           path cursor))
     (define-values (entries new-dirty)
       (for/fold ([es (hash)] [d (dirty-lines '())]) ([p (in-list plugins)])
         (define name (face-plugin-name p))
         (define o (hash-ref (plugin-slot-entries old) name (cons #f #f)))
         (define-values (st ly dl) ((face-plugin-change p) (car o) (cdr o) cctx))
         (values (hash-set es name (cons st ly)) (dirty-union d dl))))
     (plugin-slot path plugins entries (dirty-union (plugin-slot-dirty old) new-dirty))]))

;; fork：文档编辑时由槽系统调用（光标在下一次写回时再带上）。
(define (plugin-slot-fork old ctx)
  (slot-advance old
                (fork-ctx-old-text ctx) (fork-ctx-new-text ctx)
                (fork-ctx-changes ctx) #f))

(define-document-slot plugin-state #:default #f #:fork (transform plugin-slot-fork))

;;; ---------- 渲染前增量写回 ----------

;; 各插件的当前层，按目录顺序。
(define (slot-layers sl)
  (for/list ([p (in-list (plugin-slot-plugins sl))])
    (cdr (hash-ref (plugin-slot-entries sl) (face-plugin-name p)))))

;; 编辑视图当前光标点 (cons line col) | #f（不在该文档 → #f）。
(define (session-cursor-point s did)
  (define vid (session-edit-vid s))
  (cond
    [(not vid) #f]
    [(not (eqv? did (session-view-did s vid))) #f]
    [else (cons (session-view-point-line s vid)
                (session-view-point-column s vid))]))

(define (session-doc-plugins-apply s)
  (for/fold ([s s]) ([did (in-list (session-document-ids s))])
    (define path (session-file-path s did))
    (cond
      [(not path) s]
      [else
       (define sl0 (session-doc-slot-ref s did plugin-state))
       (define ps (if sl0 (plugin-slot-plugins sl0) (session-doc-plugins s did)))
       (cond
         [(null? ps) s]
         [else
          (define text (session-document-track s did))
          ;; 有编辑 → fork 已推进；这里再用（空 changes + 光标）让插件判定是否「编辑完」。
          (define sl (slot-advance (or sl0 (slot-open path ps text))
                                   text text '() (session-cursor-point s did)))
          (define s1 (session-doc-face-lines! s did (slot-layers sl) (plugin-slot-dirty sl)))
          (session-doc-slot-set! s1 did plugin-state
                                 (struct-copy plugin-slot sl [dirty (dirty-lines '())]))])])))
