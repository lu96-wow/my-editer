#lang racket

;;; edit-rebuild/plugins/lang/word-index.rkt —— 每文档增量词表（纯）
;;;
;;; 维护「行 → token」+「词 → 词频」：整篇扫一次建表，之后每次编辑只重算被改动的
;;; 那几行，均摊 O(改动)。给补全的 dabbrev 用，避免每键/每词扫全文。
;;;
;;; 与高亮影子文本同一套 edit 约定（见 core/text/base/change.rkt）：
;;;   change = {before, after}；before 是编辑前坐标、after 是编辑后坐标。
;;;   同一批 change 在**同一编辑前坐标系**、互不重叠 → 从右往左应用。
;;;
;;; 单行替换走 vector-set!（O(1)）；只有增删换行才重建 vector（memcpy）。
;;; 状态**原地更新**（#:mutable）：调用方（补全服务）按 did 持有并对版本负责
;;; （句柄不符时整篇重建）。

(require racket/list
         racket/match
         racket/string
         (only-in "../../../core/text/base/line.rkt" string->lines)
         (only-in "../../../core/text/base/track.rkt" track-ref track-length)
         (only-in "../../../core/text/base/point.rkt" point-line point-column)
         (only-in "../../../core/text/base/range.rkt" range-start range-end)
         (only-in "../../../core/text/base/change.rkt" change-before change-after)
         "../../core/face/lex.rkt")

(provide word-index-open word-index-update word-index-words track-range-text)

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

;;; ================= 从新文本轨取一次变更插入的文本 =================

;; 取新轨上 [range 的 start, end) 的文本（用于增量喂 inserted）。
(define (track-range-text t r)
  (define a (range-start r))
  (define b (range-end r))
  (define la (point-line a)) (define ca (point-column a))
  (define lb (point-line b)) (define cb (point-column b))
  (cond
    [(= la lb) (substring (track-ref t la) ca cb)]
    [else
     (string-join
      (cons (substring (track-ref t la) ca (string-length (track-ref t la)))
            (append (for/list ([l (in-range (add1 la) lb)]) (track-ref t l))
                    (list (substring (track-ref t lb) 0 cb))))
      "\n")]))

;;; ================= 增量 =================

;; 用一次编辑的 changes（编辑前坐标）+ 新文本轨增量更新；坐标越界 → 整篇重建。
;; changes 为空（如 undo 不报 changes）→ 原样返回（由调用方的版本校验兜底）。
(define (word-index-update w changes new-track)
  (cond
    [(null? changes) w]
    [else
     (define edits
       (for/list ([ch (in-list changes)])
         (define b (change-before ch))
         (list (point-line (range-start b)) (point-column (range-start b))
               (point-line (range-end b))   (point-column (range-end b))
               (track-range-text new-track (change-after ch)))))
     (cond
       [(word-index-fits? w edits) (word-index-change w edits) w]
       [else (word-index-open (track->string new-track))])]))

;; edits 的坐标是否都落在影子文本合法域内。影子只由 after-edit 维护，
;; 而程序写入（session-ed-assign!）/ undo 可能不过 after-edit —— 一旦发生，坐标会越界，
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
  (for ([e (in-list (sort edits edit>?))]) (apply-edit! w e))
  w)

(define (edit>? a b)
  (define la (car a)) (define ca (cadr a))
  (define lb (car b)) (define cb (cadr b))
  (or (> la lb) (and (= la lb) (> ca cb))))

(define (apply-edit! w e)
  (match-define (list l0 c0 l1 c1 inserted) e)
  (define lines (wi-lines w))
  (define lt (wi-line-toks w))
  (define counts (wi-counts w))
  ;; 先减掉旧行 token
  (for ([i (in-range l0 (add1 l1))]) (remove-tokens! counts (vector-ref lt i)))
  ;; 拼出新块的行
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
  (for ([toks (in-list new-lt)]) (add-tokens! counts toks))
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

(define (track->string t)
  (string-join (for/list ([i (in-range (track-length t))]) (track-ref t i)) "\n"))

;;; ================= 查询 =================

(define (word-index-words w #:min-length [min-length 2])
  (for/list ([(s _n) (in-hash (wi-counts w))]
             #:when (>= (string-length s) min-length))
    s))

;;; ================= 内部：词频 =================

(define (add-tokens! counts toks)
  (for ([s (in-list toks)])
    (hash-set! counts s (add1 (hash-ref counts s 0)))))

(define (remove-tokens! counts toks)
  (for ([s (in-list toks)])
    (define n (hash-ref counts s 0))
    (cond [(<= n 1) (hash-remove! counts s)]
          [else (hash-set! counts s (sub1 n))])))
