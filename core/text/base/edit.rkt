#lang racket

(require "track.rkt" "line.rkt" "point.rkt" "range.rkt" "change.rkt")

;;; base/edit.rkt —— 编辑：对轨 / 行的操作（底层，与文本/属性域无关）
;;;
;;; 一个**编辑**就是一条 track 的变换：
;;;
;;;     编辑 : track -> track
;;;
;;; 因为文本轨和属性轨是同一种 track，同一个编辑能一视同仁地作用在谁身上。
;;; 两级编辑：
;;;     行级  edit-lines …      换行区间
;;;     格级  edit-range …      换文档区间 [l0,c0) .. (l1,c1)，可跨行、可含 \n（粘贴）
;;; 格级编辑按行 payload 类型分派：string 走文本（拼字符），vector 走属性（按 sticky 拼符号）。
;;; 同一段 text 在两条轨上会拆成**同样的行划分**，所以文本与属性始终对齐。

(provide
 ;; ---------- 多轨 ----------
 map-edits

 ;; ---------- 行级编辑 ----------
 edit-lines edit-insert-lines edit-delete-lines edit-rewrite-line

 ;; ---------- 格级编辑（跨行） ----------
 edit-range edit-cells edit-insert-text edit-delete-range edit-delete-cells edit-fill

 ;; ---------- span / 位置代数 ----------
 (struct-out span) span->edit span-after-position span->change)

;;; ---------- 多轨 ----------

(define (map-edits edits tracks)
  (define ne (length edits))
  (define nt (length tracks))
  (unless (= ne nt)
    (error 'map-edits "edits 与 tracks 数量不一致: ~a vs ~a" ne nt))
  (for/list ([ed (in-list edits)] [t (in-list tracks)]) (ed t)))

;;; ---------- 行级编辑（对所有轨道都是同一个函数） ----------

(define (edit-lines s e lines) (lambda (t) (track-splice t s e lines)))
(define (edit-insert-lines s lines) (lambda (t) (track-splice t s s lines)))
(define (edit-delete-lines s e) (lambda (t) (track-splice t s e '())))
;; 重写第 i 行：f : 行 payload -> 行 payload。
(define (edit-rewrite-line i f) (lambda (t) (track-rewrite t i f)))

;;; ---------- 格级编辑（跨行；按行类型分派） ----------

;; 文本行：head ++ 粘贴行 ++ tail（按 \n 拆）。
(define (text-splice-lines line0 c0 line1 c1 text)
  (define pieces (string->lines text))
  (define head (substring line0 0 c0))
  (define tail (substring line1 c1))
  (define k (length pieces))
  (cond
    [(= k 1) (list (string-append head (car pieces) tail))]
    [else (append (list (string-append head (car pieces)))
                  (drop-right (rest pieces) 1)
                  (list (string-append (last pieces) tail)))]))

;; 属性行：与文本同样的行划分；每行插入「该文本行字符数」个符号（按 sticky）。
(define (attr-splice-lines line0 c0 line1 c1 text sticky default)
  (define val
    (case sticky
      [(none) default]
      [(left) (if (> c0 0) (line-ref line0 (sub1 c0)) default)]
      [(right) (if (< c1 (line-length line1)) (line-ref line1 c1) default)]
      [else (error 'edit-range "sticky 必须是 'none / 'left / 'right，得到 ~a" sticky)]))
  (define pieces (string->lines text))
  (define (cells s) (line-of-like line0 (make-list (string-length s) val)))
  (define head (line-slice line0 0 c0))
  (define tail (line-slice line1 c1 (line-length line1)))
  (define k (length pieces))
  (cond
    [(= k 1) (list (line-append (line-append head (cells (car pieces))) tail))]
    [else (append (list (line-append head (cells (car pieces))))
                  (map cells (drop-right (rest pieces) 1))
                  (list (line-append (cells (last pieces)) tail)))]))

;; 把文档区间 [l0,c0) .. (l1,c1) 换成 text（可含 \n，可跨行）。
(define (edit-range l0 c0 l1 c1 text [sticky 'none] [default #f])
  (lambda (t)
    (define line0 (track-ref t l0))
    (define line1 (track-ref t l1))
    (define new-lines
      (if (string? line0)
          (text-splice-lines line0 c0 line1 c1 text)
          (attr-splice-lines line0 c0 line1 c1 text sticky default)))
    (track-splice t l0 (add1 l1) new-lines)))

;; 单行 / 插入 / 删除 都是 edit-range 的糖。
(define (edit-cells i c0 c1 text [sticky 'none] [default #f])
  (edit-range i c0 i c1 text sticky default))
(define (edit-insert-text i c text [sticky 'none] [default #f])
  (edit-range i c i c text sticky default))
(define (edit-delete-range l0 c0 l1 c1)
  (edit-range l0 c0 l1 c1 ""))
(define (edit-delete-cells i c0 c1) (edit-delete-range i c0 i c1))

;; 把 [l0,c0)..(l1,c1) 的所有格设为 val（不改行结构）。用于属性赋值（也可用于文本行）。
(define (edit-fill l0 c0 l1 c1 val)
  (lambda (t)
    (define new-lines
      (for/list ([i (in-range l0 (add1 l1))])
        (define l (track-ref t i))
        (define a (if (= i l0) c0 0))
        (define b (if (= i l1) c1 (line-length l)))
        (line-splice l a b (line-of-like l (make-list (- b a) val)))))
    (track-splice t l0 (add1 l1) new-lines)))

;;; ---------- span：区间替换 + 位置代数（多光标编辑用） ----------
;;; span = 把 [start,end) 换成 text（坐标 = 编辑前）。与 edit-range 描述同一件事，
;;; 但 span 是**值**：可施加（span->edit）、也可映射位置（span->change）。
;;;
;;; span 是**输入**（要 text 才能施加编辑）；change 是**输出**（改了什么，只存结构）。

(struct span (start end text) #:transparent)

;; span → 编辑闭包（track -> track）。
(define (span->edit sp [sticky 'none] [default #f])
  (edit-range (point-line (span-start sp)) (point-column (span-start sp))
              (point-line (span-end sp)) (point-column (span-end sp))
              (span-text sp) sticky default))

;; 插入文本之后的点。
(define (span-after-position sp)
  (define s (span-start sp))
  (define text (span-text sp))
  (define lines (string->lines text))
  (define k (length lines))
  (cond
    [(= k 1) (point (point-line s) (+ (point-column s) (string-length text)))]
    [else (point (+ (point-line s) (sub1 k)) (string-length (last lines)))]))

;;; ---------- span → change ----------

;; span → change：before = 被替换区间；after = 插入文本占的区间。
;; 前缀不动，所以 after.start = before.start。文本内容不进 change。
(define (span->change sp)
  (change (range-of (span-start sp) (span-end sp))
          (range-of (span-start sp) (span-after-position sp))))
