#lang racket

(require "cursor.rkt" "content.rkt" rackunit)

;;; marker.rkt —— 随编辑自动移动的位置
;;;
;;; 每个 marker 有 id 和 insertion-type：
;;;   'before  在 marker 位置插入时，marker 不动（留在新字符左边）
;;;   'after   在 marker 位置插入时，marker 跟随新字符
;;;
;;; insertion-type 只在 insert-char / newline 于 marker 位置时起作用。
;;; 删除和合并是纯位置映射，与 type 无关。
;;;
;;; 所有调整按 edit-desc 的「操作前坐标」。

(provide
 (struct-out marker)
 (struct-out marker-table)
 make-marker-table
 marker-table-add
 marker-table-remove
 marker-table-get
 marker-table-all
 marker-table-count
 marker-apply-edit
 marker-table-apply-edit)

(struct marker (id pos insertion-type) #:transparent)
;; pos : cursor

(struct marker-table (next-id markers by-id) #:transparent)
;; markers : (listof marker)     迭代顺序（创建顺序）
;; by-id   : (hashof id marker)  O(1) 查找

;;; ---------- 表管理 ----------

(define (make-marker-table) (marker-table 0 '() (hash)))

(define (marker-table-add mt pos [type 'before])
  (unless (memq type '(before after))
    (error 'marker-table-add "insertion-type must be 'before or 'after, got ~a" type))
  (define id (marker-table-next-id mt))
  (define m (marker id pos type))
  (values (marker-table (add1 id)
                        (cons m (marker-table-markers mt))
                        (hash-set (marker-table-by-id mt) id m))
          id))

(define (marker-table-remove mt id)
  (marker-table (marker-table-next-id mt)
                (filter (lambda (m) (not (= (marker-id m) id)))
                        (marker-table-markers mt))
                (hash-remove (marker-table-by-id mt) id)))

(define (marker-table-get mt id)
  (hash-ref (marker-table-by-id mt) id #f))

(define (marker-table-all mt) (marker-table-markers mt))
(define (marker-table-count mt) (length (marker-table-markers mt)))

;;; ---------- 单 marker 调整 ----------

(define (marker-apply-edit m desc)
  (match-define (edit-desc kind line col) desc)
  (define p (marker-pos m))
  (define l (cursor-line p))
  (define c (cursor-col p))
  (define t (marker-insertion-type m))
  (define p*
    (match kind
      ;; 在 (line, col) 前插入一个字符。
      ['insert-char
       (cond [(< l line) p]
             [(> l line) p]
             [(< c col) p]
             [(= c col) (if (eq? t 'after) (cursor l (add1 c)) p)]
             [else (cursor l (add1 c))])]

      ;; 在 (line, col) 处拆行。
      ['newline
       (cond [(< l line) p]
             [(= l line)
              (cond [(< c col) p]
                    [(= c col) (if (eq? t 'after) (cursor (add1 l) 0) p)]
                    [else (cursor (add1 l) (- c col))])]
             [else (cursor (add1 l) c)])]

      ;; 删除 (line, col) 处的字符。
      ['backspace-char
       (cond [(< l line) p]
             [(> l line) p]
             [(<= c col) p]
             [else (cursor l (sub1 c))])]

      ['delete-char
       ;; 与 backspace-char 位置映射完全相同。
       (cond [(< l line) p]
             [(> l line) p]
             [(<= c col) p]
             [else (cursor l (sub1 c))])]

      ;; merge：desc.line = 被合并行 L，拼接点在 (L-1, col)。
      ;; 两种 merge 字面同构。
      ['backspace-merge
       (cond [(< l line) p]
             [(= l line) (cursor (sub1 l) (+ col c))]
             [else (cursor (sub1 l) c)])]

      ['delete-merge
       (cond [(< l line) p]
             [(= l line) (cursor (sub1 l) (+ col c))]
             [else (cursor (sub1 l) c)])]))
  (marker (marker-id m) p* t))

;;; ---------- 批量调整 ----------

(define (marker-table-apply-edit mt desc)
  (define ms (map (lambda (m) (marker-apply-edit m desc))
                  (marker-table-markers mt)))
  (marker-table (marker-table-next-id mt)
                ms
                (for/hash ([m (in-list ms)]) (values (marker-id m) m))))