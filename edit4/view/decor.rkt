#lang racket

;;; edit4/view/decor.rkt —— 装饰：引擎 document 槽 + 增量写回
;;;
;;; 装饰的增量状态（每个 decor 的 state + 层 track + 脏行）挂在**引擎 document 槽**
;;; `decor-state` 上：文本编辑时由引擎 `fork-slots` 自动推进（拿到 changes），undo 回放旧
;;; document 即得旧层；渲染前再推进一次（空 changes + 当前光标）处理光标移动 / 收尾。
;;;
;;;   decor-slot : path + decors + entries(与 decors 平行的 (state . layer)) + dirty
;;;   写回       : 只重写脏行：先清该行旧 face，再按 decor 顺序逐格 face-compose。
;;;
;;; 具体装饰（syntax/word-color/…）在 decor/ 下；本模块只管槽 / 驱动 / 组合 / 写回。

(provide apply-faces!)

(require (except-in racket/list range)
         "face.rkt"
         "../core/world.rkt"
         "../../core/editor.rkt"
         "../content/adapter.rkt"
         (only-in "../content/model.rkt"
                  content-ed content-bindings content-panel? content-doc-meta doc-path)
         "../decor/protocol.rkt"
         "../decor/dirty.rkt"
         (only-in "../../core/text/base/track.rkt" track-length track-ref))

;;; ---------- 槽 ----------

(struct decor-slot (path decors entries dirty) #:transparent)
;; path    : path | #f
;; decors  : (listof decor)                该文档适用的装饰（含装配期烘焙的 #:applies?）
;; entries : (listof (cons state layer))   与 decors 平行
;; dirty   : dirty                         上次写回以来累积的脏行

;; 幕次推进：给各 decor 一个 face-ctx，累积 state / 层 / 脏行。
(define (slot-advance sl old-text new-text changes cursor)
  (define ctx (face-ctx old-text new-text changes
                        (dirty-lines (changes->dirty-lines changes))
                        (decor-slot-path sl) cursor))
  (define-values (rev-entries dirty)
    (for/fold ([es '()] [d (dirty-lines '())])
              ([dec (in-list (decor-slot-decors sl))]
               [e (in-list (decor-slot-entries sl))])
      (define-values (st ly dl) ((decor-change dec) (car e) (cdr e) ctx))
      (values (cons (cons st ly) es) (dirty-union d dl))))
  (struct-copy decor-slot sl
               [entries (reverse rev-entries)]
               [dirty (dirty-union (decor-slot-dirty sl) dirty)]))

;; 首次：整篇 open，脏 = 全篇。
(define (slot-open path decors text)
  (define entries
    (for/list ([dec (in-list decors)])
      (define-values (st ly) ((decor-open dec) path text))
      (cons st ly)))
  (decor-slot path decors entries (dirty-all)))

;; 引擎 fork：文本编辑时由 document-edit-tracks 调用（带 changes）。
(define (decor-slot-fork old ctx)
  (cond
    [(not old) #f]                                    ; 尚未 open：编辑期不推进
    [else (slot-advance old (fork-ctx-old-text ctx) (fork-ctx-new-text ctx)
                        (fork-ctx-changes ctx) #f)]))

(define-document-slot decor-state #:default #f #:fork (transform decor-slot-fork))

;;; ---------- 组合 / 写回 ----------

;; 可见的非面板文档视图（did 去重，取第一个）：(listof (list did vid))
(define (visible-doc-views w)
  (define c (world-content w))
  (cond
    [(not c) '()]
    [else
     (define ed (content-ed c))
     (define seen (make-hash))
     (for/fold ([acc '()]) ([(id vid) (in-hash (content-bindings c))])
       (define did (and vid (view-did ed vid)))
       (cond
         [(or (not did) (content-panel? c vid) (hash-has-key? seen did)) acc]
         [else (hash-set! seen did #t) (cons (list did vid) acc)]))]))

;; 一个格子的最终 face：把各层在同一位置的 face 逐个 compose（后层覆盖前层）。
(define (cell-face layers ln i)
  (foldl (lambda (elem acc) (face-compose acc elem)) #f
         (for/list ([ly (in-list layers)]
                    #:when (and ly (< ln (track-length ly))))
           (define vec (track-ref ly ln))
           (and vec (< i (vector-length vec)) (vector-ref vec i)))))

;; 只写脏行：先清该行旧 face，再按组合结果写 fills。
(define (write-dirty! ed did text sl)
  (define lines (track->lines text))
  (define n (length lines))
  (define dls (dirty->lines (decor-slot-dirty sl) n))
  (when (pair? dls)
    (define layers (map cdr (decor-slot-entries sl)))
    (face-batch! ed did (for/list ([ln (in-list dls)])
                          (list ln 0 ln (string-length (list-ref lines ln)) #f)))
    (define fills
      (append*
       (for/list ([ln (in-list dls)])
         (define len (string-length (list-ref lines ln)))
         (define vec (for/vector ([i (in-range len)]) (cell-face layers ln i)))
         (for/list ([r (in-list (face-runs vec))]) (list ln (car r) ln (cadr r) (caddr r))))))
    (when (pair? fills) (face-batch! ed did fills))))

;;; ---------- 对外 ----------

;; apply-faces! : engine decors World -> void
;; 每帧：逐可见文档推进槽（空 changes + 光标）→ 写回脏行 → 清脏。
(define (apply-faces! ed decors w)
  (define c (world-content w))
  (for ([dv (in-list (visible-doc-views w))])
    (define did (car dv))
    (define vid (cadr dv))
    (define text (document-track ed did))
    (define path (doc-path (content-doc-meta c did)))
    (define cursor (cons (view-line ed vid) (view-col ed vid)))
    (define sl0 (editor-document-slot-ref ed did decor-state))
    (define sl (if sl0 sl0 (slot-open path decors text)))
    (define sl* (slot-advance sl text text '() cursor))
    (write-dirty! ed did text sl*)
    (editor-document-slot-set! ed did decor-state
                               (struct-copy decor-slot sl* [dirty (dirty-lines '())]))))
