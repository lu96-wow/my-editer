#lang racket

;;; layer  : effects
;;; effect : **document slot + core face port 的写回**
;;;
;;; effects/paint.rkt —— 增量 face 装饰的运行时载体
;;;
;;; 每个 document 一个 `face-paint` slot：
;;;
;;;   decors  : (listof face-decor)          打开时固定（已按 applies? 过滤）
;;;   entries : (listof (cons state layer))  与 decors 平行
;;;   static  : (hash/c symbol track)         set-face-layer-effect 的一次性层
;;;   path    : path | #f
;;;   dirty   : dirty                         待写回 core face port 的行
;;;
;;; 文本编辑时 core 的 `document-edit-tracks` 会 fork 这个 slot：
;;;
;;;   · 调每个 decor 的 change，拿回新的 state / layer / dirty；
;;;   · 静态层用 fork-ctx-edit 自动做同样的结构平移；
;;;   · 结果只保留“脏行”，写回时只改那些行的 core face 单元。
;;;
;;; undo / redo 换回旧 document 时，旧 slot 和旧 face port 一起回来，不需要重算。
;;;
;;; 这里仍然只有主线程写 core；没有后台线程、没有锁。
;;; 跨模块配合 / 特殊约束见 CONSTRAINTS.md §4。

(provide (struct-out paint-state)
         paint-open!
         paint-reset!
         paint-advance!
         paint-write!
         paint-set-static-layer!
         fills->layer-track)

(require (except-in racket/list range)
         racket/match
         "../../core/text/slot-dsl.rkt"
         "../../core/text/slots.rkt"
         "../../core/text/document.rkt"
         "../../core/text/base/track.rkt"
         "../../core/text/base/line.rkt"
         "../../core/editor/state.rkt"
         "../../core/editor/attributes.rkt"
         "../model/face-decor.rkt"
         "../model/face-layer.rkt")

;;; ════════════════ 状态 ════════════════

(struct paint-state (decors entries static path dirty) #:transparent)
;; decors  : (listof face-decor)
;; entries : (listof (cons state layer))
;; static  : (hash/c symbol track)
;; path    : path | #f
;; dirty   : dirty

;; slot 的 fork transform 在 core 的 document-edit-tracks 里执行。
;; 注意：slot 的注册必须在 paint-fork 定义之后（transform 参数在定义时求值）。

(define (paint-state-of b)
  (document-slot-face-paint (buffer-document b)))

(define (set-paint-state! b ps)
  (document-set-slot-face-paint! (buffer-document b) ps)
  (void))

;;; ════════════════ 打开 / 重置 ════════════════

;; 新文档或整篇替换后：每个 decor 从当前文本整篇 open；stage = dirty-all。
(define (paint-open! b decors path order)
  (define doc (buffer-document b))
  (define text (document-text doc))
  (define entries
    (for/list ([dec (in-list decors)])
      (define-values (state layer) ((face-decor-open dec) path text))
      (cons state layer)))
  (define ps (paint-state decors entries (hash) path
                          (if (null? decors) (dirty-lines '()) (dirty-all))))
  (set-paint-state! b ps)
  (paint-write! b order)
  (void))

;; 整篇设置文本（set-text-effect）之后用：丢弃旧 slot，按当前 decors 重新 open。
(define (paint-reset! b decors path order)
  (paint-open! b decors path order))

;;; ════════════════ fork：文本编辑时推进 ════════════════

(define (paint-fork old ctx)
  (define old-text (fork-ctx-old-text ctx))
  (define new-text (fork-ctx-new-text ctx))
  (define changes (fork-ctx-changes ctx))
  (define dirty0 (changes->dirty-lines changes))

  ;; 静态层没有自己的 change：用同一个编辑函数做结构平移。
  (define edit (fork-ctx-edit ctx))
  (define static*
    (for/hash ([(id tr) (in-hash (paint-state-static old))])
      (values id (edit tr))))

  ;; decor 的结构平移由 decor 自己负责（refresh-layer / stateful-advance）。
  ;; CONSTRAINT: 旧 dirty 必须并进来。多光标编辑是多次 document-edit-tracks，
  ;; 前面 span 的脏行还没写回，不能被后一次 fork 覆盖掉（CONSTRAINTS §4.1）。
  (define-values (entries* dirty*)
    (for/fold ([entries* '()] [dirty* (dirty-union (paint-state-dirty old) dirty0)])
              ([dec (in-list (paint-state-decors old))]
               [entry (in-list (paint-state-entries old))])
      (define cctx (face-ctx old-text new-text changes dirty0
                             (paint-state-path old) #f))
      (define-values (state layer d)
        ((face-decor-change dec) (car entry) (cdr entry) cctx))
      (values (cons (cons state layer) entries*)
              (dirty-union dirty* d))))

  (paint-state (paint-state-decors old)
               (reverse entries*)
               static*
               (paint-state-path old)
               dirty*))

;; slot 的注册放在 paint-fork 之后。
(define-document-slot face-paint
  #:default (paint-state '() '() (hash) #f (dirty-lines '()))
  #:fork (transform paint-fork))

;;; ════════════════ 光标推进 ════════════════

;; cursor = (cons line col) | #f。changes = '()，只让光标相关 decor 标脏。
(define (paint-advance! b cursor order)
  (define ps (paint-state-of b))
  (cond
    [(or (not cursor) (null? (paint-state-decors ps))) (void)]
    [else
     (define doc (buffer-document b))
     (define text (document-text doc))
     (define-values (entries* dirty*)
       (for/fold ([entries* '()] [dirty* (paint-state-dirty ps)])
                 ([dec (in-list (paint-state-decors ps))]
                  [entry (in-list (paint-state-entries ps))])
         (define cctx (face-ctx text text '() (dirty-lines '())
                                (paint-state-path ps) cursor))
         (define-values (state layer d)
           ((face-decor-change dec) (car entry) (cdr entry) cctx))
         (values (cons (cons state layer) entries*)
                 (dirty-union dirty* d))))
     (set-paint-state! b (struct-copy paint-state ps
                                     [entries (reverse entries*)]
                                     [dirty dirty*]))
     (paint-write! b order)]))

;;; ════════════════ 静态层（set-face-layer-effect） ════════════════

(define (paint-set-static-layer! b layer fills order)
  (define ps (paint-state-of b))
  (define static* (if (null? fills)
                      (hash-remove (paint-state-static ps) layer)
                      (hash-set (paint-state-static ps) layer
                                (fills->layer-track b fills))))
  (set-paint-state! b (struct-copy paint-state ps
                                   [static static*]
                                   [dirty (dirty-all)]))
  (paint-write! b order)
  (void))

;; fills 坐标是 (line col)，半开区间；越界夹到当前文本。
(define (fills->layer-track b fills)
  (define text (document-text (buffer-document b)))
  (define lines
    (for/list ([line (in-list (track->list text))])
      (make-vector (string-length line) #f)))
  (define n (length lines))
  (for ([f (in-list fills)])
    (match-define (list l0 c0 l1 c1 v) f)
    (for ([ln (in-range (max 0 l0) (min n (add1 l1)))])
      (define vec (list-ref lines ln))
      (define len (vector-length vec))
      (define a (if (= ln l0) (max 0 (min c0 len)) 0))
      (define b (if (= ln l1) (max 0 (min c1 len)) len))
      (for ([i (in-range a (max a b))])
        (vector-set! vec i v))))
  (track-of-list lines))

;;; ════════════════ 写回 ════════════════

;; 只重写 dirty 行：先清该行，再按层序合成后的 runs 写回。
(define (paint-write! b order)
  (define ps (paint-state-of b))
  (define doc (buffer-document b))
  (define text (document-text doc))
  (define dls (dirty->lines (paint-state-dirty ps) (track-length text)))
  (cond
    [(null? dls) (void)]
    [else
     (define decor-layers
       (for/fold ([h (hash)]) ([dec (in-list (paint-state-decors ps))]
                                [entry (in-list (paint-state-entries ps))])
         (hash-set h (face-decor-layer dec) (cdr entry))))
     (define static (paint-state-static ps))
     (define ids
       (remove-duplicates
        (append (hash-keys decor-layers) (hash-keys static))))
     (define ordered
       (append (for/list ([id (in-list order)] #:when (memq id ids)) id)
               (sort (for/list ([id (in-list ids)] #:unless (memq id order)) id)
                     symbol<?)))
     (define tracks
       (for/list ([id (in-list ordered)])
         (or (hash-ref decor-layers id #f)
             (hash-ref static id #f))))
     (define fills
       (append*
        (for/list ([ln (in-list dls)])
          (define len (track-line-length text ln))
          (define vec
            (for/vector ([i (in-range len)])
              (for/fold ([f #f]) ([tr (in-list tracks)])
                (define row (and tr (< ln (track-length tr)) (track-ref tr ln)))
                (define cell (and row (< i (vector-length row)) (vector-ref row i)))
                (compose-face f cell))))
          (cons (list ln 0 ln len #f)
                (for/list ([r (in-list (face-runs vec))])
                  (list ln (list-ref r 0) ln (list-ref r 1) (list-ref r 2)))))))
     (buffer-face-batch! b fills)
     (set-paint-state! b (struct-copy paint-state ps [dirty (dirty-lines '())]))
     (void)]))
