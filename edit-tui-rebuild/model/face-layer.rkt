#lang racket

;;; model/face-layer.rkt —— face 分层合成（纯）
;;; layer  : model
;;; effect : 无（纯数据 + 纯函数）
;;;
;;; 为什么需要“层”：允许多个插件各写**一个 face 分量**，互不覆盖。
;;;   例：一个插件写前景（语法），另一个写背景（括号深度）；
;;;       同一格上两个分量都在，按层序合并成一个 face。
;;;
;;; face 三分量见 `edit-tui/base/face.rkt`：
;;;   fg    : #f | symbol
;;;   bg    : #f | symbol
;;;   attrs : (listof symbol)
;;;
;;; 规矩：
;;;   · 插件只写自己负责的分量：
;;;       `(face-set-fg face-empty 'fg-syntax-def)`   —— 前景
;;;       `(face-set-bg face-empty 'bg-depth-1)`      —— 背景
;;;   · 合并 = **按层序**逐分量覆盖：后一层的非 #f 分量覆盖前面的，attrs 取并集；
;;;   · 裸符号（整 style 名）表示“整格换风格”，不参与分量合并（后者整体覆盖）；
;;;   · 层序是数据（`environment.face-layers`，越靠后越“在上面”）。
;;;
;;; fills 形状沿用 core：`(list l0 c0 l1 c1 face)`，区间半开 [c0, c1)。
;;; 合成结果同样是 fills —— 引擎只需要一次 `buffer-face-batch!` 写回。
;;;
;;; 本模块**重导出** base 的 face 读写操作，插件 require 一个就够。

(provide (struct-out face)
         face-empty
         face-set-fg face-set-bg face-set-attrs
         face-add-attr face-remove-attr face-has-attr?
         compose-face
         compose-layers)

(require "../base/face.rkt")

;;; ════════════════ 合并两个 face ════════════════

;; new 的非 #f 分量覆盖 old；attrs 取并集（保序、去重）。
;; 任一侧是裸符号（整 style 名）→ 整体覆盖（分量语义不适用）。
(define (compose-face old new)
  (cond
    [(not new) old]
    [(not old) new]
    [(or (symbol? old) (symbol? new)) new]
    [else
     (face (or (face-fg new) (face-fg old))
           (or (face-bg new) (face-bg old))
           (remove-duplicates (append (face-attrs old) (face-attrs new))))]))

;;; ════════════════ 多层 fills 合成 ════════════════

;; order  : (listof symbol)                 层序（先低后高）
;; layers : (hash/c symbol (listof fill))   每层的 fills
;; → fills: 合成后的 fills（按行、列升序；相邻同 face 合并）
;;
;; 没在 order 里出现的层：按名字排在已声明的层**之后**（不至于被静默丢掉）。
;; 正确做法仍然是在插件里 `#:env #:face-layers (list 自己的层)` 声明。
(define (compose-layers order layers)
  (define effective-order
    (append order
            (sort (for/list ([k (in-hash-keys layers)] #:unless (memq k order)) k)
                  symbol<?)))
  ;; 1. 展开成稀疏格：(line . col) -> face
  (define cells (make-hash))
  (for ([layer (in-list effective-order)])
    (for ([f (in-list (hash-ref layers layer '()))])
      (match-define (list l0 c0 l1 c1 v) f)
      (for ([l (in-range l0 (add1 l1))])
        (define a (if (= l l0) c0 0))
        (define b (if (= l l1) c1 +inf.0))
        (for ([c (in-range a b)])
          (define k (cons l c))
          (hash-set! cells k (compose-face (hash-ref cells k #f) v))))))
  ;; 2. 按 (行, 列) 排序，合并相邻同 face 的格
  (define ks (sort (hash-keys cells)
                   (λ (a b) (or (< (car a) (car b))
                                (and (= (car a) (car b)) (< (cdr a) (cdr b)))))))
  (reverse
   (for/fold ([acc '()]) ([k (in-list ks)])
     (define l (car k)) (define c (cdr k)) (define v (hash-ref cells k))
     (cond
       [(and (pair? acc)
             (= (list-ref (car acc) 0) l)
             (= (list-ref (car acc) 3) c)            ; 与前一格相邻
             (equal? (list-ref (car acc) 4) v))
        (cons (list (list-ref (car acc) 0) (list-ref (car acc) 1) l (add1 c) v)
              (cdr acc))]
       [else (cons (list l c l (add1 c) v) acc)]))))
