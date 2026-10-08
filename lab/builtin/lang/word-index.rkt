#lang racket

;;; lab/builtin/lang/word-index.rkt —— 每文档增量词表（纯）
;;;
;;; 维护「行 → token」+「词 → 词频」：整篇扫一次建表，之后每次编辑只重算被改动的
;;; 那几行，均摊 O(改动)。给补全的 dabbrev 用，避免每键/每词扫全文。
;;;
;;; 与高亮影子文本同一套 edit 约定（见 builtin/highlight/shadow.rkt）：
;;;   edit = (list l0 c0 l1 c1 inserted)：把编辑前坐标 [l0,c0)-(l1,c1) 替换成 inserted。
;;;   同一批 edit 在**同一编辑前坐标系**、互不重叠 → 从右往左应用。
;;;
;;; 单行替换走 vector-set!（O(1)）；只有增删换行才重建 vector（memcpy）。

(require racket/list
         racket/match
         racket/string
         "../../../core/text/base/line.rkt"
         "lex.rkt")

(provide word-index-open word-index-change word-index-words word-index-fits?)

(struct wi (lines line-toks counts) #:mutable #:transparent)
;; lines     : vector string            影子文本（增量重建用）
;; line-toks : vector (listof string)   每行的标识符 token
;; counts    : hash string -> nat       全文档词频（只含 ident-start? 起的词）

;; 整篇建表（首次 / 兜底重建）。
(define (word-index-open text)
  (define lines (list->vector (string->lines text)))
  (define lt (for/vector ([l (in-vector lines)]) (line-words l)))
  (define counts (make-hash))
  (for ([toks (in-vector lt)]) (add-tokens! counts toks))
  (wi lines lt counts))

;; 一行的标识符字符串（line-tokens 给的是区间）。
(define (line-words line)
  (for/list ([m (in-list (line-tokens line))]) (substring line (car m) (cdr m))))

;;; ================= 增量 =================

;; edits 的坐标是否都落在影子文本合法域内。影子只由 after-edit 维护，
;; 而程序写入（editor-view-assign!）不过 after-edit —— 一旦发生，坐标会越界，
;; 调用方据此整篇重建，而不是拿旧影子硬算崩溃。
(define (word-index-fits? w edits)
  (define lines (wi-lines w))
  (define n (vector-length lines))
  (for/and ([e (in-list edits)])
    (match-define (list l0 c0 l1 c1 _inserted) e)
    (and (exact-nonnegative-integer? l0) (exact-nonnegative-integer? l1)
         (<= l0 l1) (< l1 n)
         (<= c0 (string-length (vector-ref lines l0)))
         (<= c1 (string-length (vector-ref lines l1))))))

(define (word-index-change w edits)
  (define added (make-hash))
  (for ([e (in-list (sort edits edit>?))]) (apply-edit! w e added))
  (hash-keys added))

(define (edit>? a b)
  (define la (car a)) (define ca (cadr a))
  (define lb (car b)) (define cb (cadr b))
  (or (> la lb) (and (= la lb) (> ca cb))))

(define (apply-edit! w e added)
  (match-define (list l0 c0 l1 c1 inserted) e)
  (define lines (wi-lines w))
  (define lt (wi-line-toks w))
  (define counts (wi-counts w))
  ;; 先减掉旧行 token
  (for ([i (in-range l0 (add1 l1))]) (remove-tokens! counts (vector-ref lt i)))
  ;; 拼出新块的行（与 shadow-apply 一致）
  (define head (substring (vector-ref lines l0) 0 c0))
  (define tail (substring (vector-ref lines l1) c1))
  (define ins (string->lines inserted))
  (define block
    (cond
      [(null? (cdr ins)) (list (string-append head (car ins) tail))]
      [else (append (list (string-append head (car ins)))
                    (drop-right (cdr ins) 1)
                    (list (string-append (last ins) tail)))]))
  (define new-lt (for/list ([l (in-list block)]) (line-words l)))
  (for ([toks (in-list new-lt)]) (add-tokens! counts toks added))
  ;; 单行 → 就地改；跨行 → 重建 vector
  (cond
    [(and (= l0 l1) (null? (cdr block)))
     (vector-set! lines l0 (car block))
     (vector-set! lt l0 (car new-lt))]
    [else
     (set-wi-lines! w
                    (list->vector (append (take (vector->list lines) l0)
                                          block
                                          (drop (vector->list lines) (add1 l1)))))
     (set-wi-line-toks! w
                        (list->vector (append (take (vector->list lt) l0)
                                              new-lt
                                              (drop (vector->list lt) (add1 l1)))))]))

;;; ================= 查询 =================

(define (word-index-words w #:min-length [min-length 2])
  (for/list ([(s _n) (in-hash (wi-counts w))]
             #:when (>= (string-length s) min-length))
    s))

;;; ================= 内部：词频 =================

(define (add-tokens! counts toks [added #f])
  (for ([s (in-list toks)])
    (define n (hash-ref counts s 0))
    (when (and added (zero? n)) (hash-set! added s #t))
    (hash-set! counts s (add1 n))))

(define (remove-tokens! counts toks)
  (for ([s (in-list toks)])
    (define n (hash-ref counts s 0))
    (cond [(<= n 1) (hash-remove! counts s)]
          [else (hash-set! counts s (sub1 n))])))
