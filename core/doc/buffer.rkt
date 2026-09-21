#lang racket

(require "../atom/point.rkt" "../atom/content.rkt" "../atom/edit.rkt"
         "../atom/selection.rkt" rackunit)

;;; doc/buffer.rkt —— 纯文本值：content + tick
;;;
;;; **不再含 attrs，也不含任何编辑施加**。buffer 只回答「文本是什么、行/列几何、
;;; 文本版本号」；一切编辑（文本 + 属性）在 doc/document.rkt 的漏斗里发生。
;;;
;;;   buffer = content ⊕ tick        tick = 本 buffer 的版本戳（由 document 漏斗 +1）
;;;
;;; 文本动作（buffer-op-*）与逆（buffer-edit-desc-inverse）只依赖 content，
;;; 输出 edit-desc 值，不施加——施加是 document 的事。

(provide
 buffer?                            ; 构造器/内部字段不外露（避免绕过不变量）
 buffer-open
 buffer-content                       ; 文本原子（供 document 漏斗）
 buffer->string
 buffer->lines
 buffer-line-count
 buffer-line-ref
 buffer-line-length
 buffer-clamp-point
 buffer-point->offset
 buffer-offset->point
 buffer-range-text
 buffer-clamp-edit-descs
 buffer-content-eq?
 buffer-tick
 buffer-set-content                   ; 仅供 document 漏斗
 buffer-bump                          ; 仅供 document 漏斗
 ;; 文本动作（可传的值；op : buffer selection → desc/#f）
 buffer-op-insert-char
 buffer-op-insert
 buffer-op-newline
 buffer-op-backspace
 buffer-op-delete
 buffer-op-splice
 buffer-edit-desc-inverse)

;;; ---------- 数据 ----------

(struct buffer
  (content ; content.rkt
   tick)   ; nat      本 buffer 的版本戳（document 漏斗每次变更 +1）
  #:transparent)

;;; ---------- 构造 / 投影 ----------

(define (buffer-open s)
  (buffer (content-of-string s) 0))

(define (buffer->string b) (content->string (buffer-content b)))
(define (buffer->lines b)  (content->lines  (buffer-content b)))
(define (buffer-line-count b) (content-line-count (buffer-content b)))
(define (buffer-line-ref b i) (content-line-ref (buffer-content b) i))
(define (buffer-line-length b i) (content-line-length (buffer-content b) i))

;; 位置解析只取决于文本，与窗口/光标/属性无关。
(define (buffer-clamp-point b p) (content-clamp-point (buffer-content b) p))
(define (buffer-point->offset b p) (content-point->offset (buffer-content b) p))
(define (buffer-offset->point b off) (content-offset->point (buffer-content b) off))

;; 文本是否同一：只有真正换 content 才不等（属性不再参与）。
(define (buffer-content-eq? a b) (eq? (buffer-content a) (buffer-content b)))

;; 换 content（保留 tick）/ 版本 +1。**仅供 document 漏斗**，不对外当编辑入口。
(define (buffer-set-content b c) (buffer c (buffer-tick b)))
(define (buffer-bump b) (struct-copy buffer b [tick (add1 (buffer-tick b))]))

;; 取区间文本（[start,end) 半开）。
(define (buffer-range-text b s e)
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (cond
    [(= sl el) (substring (buffer-line-ref b sl) sc ec)]
    [else
     (string-join
      (append (list (substring (buffer-line-ref b sl) sc
                               (string-length (buffer-line-ref b sl))))
              (for/list ([l (in-range (add1 sl) el)]) (buffer-line-ref b l))
              (list (substring (buffer-line-ref b el) 0 ec)))
      "\n")]))

;; 把一串文本 desc 夹到生效域（不动 buffer）。
(define (buffer-clamp-edit-descs b descs)
  (map (lambda (d) (content-clamp-desc (buffer-content b) d)) descs))

;;; ---------- 文本动作（只算 desc，不施加） ----------
;;; 形状统一：op : buffer selection → (or/c #f edit-desc)。

(define (buffer-op-insert text)
  (lambda (_b sel) (edit-desc (selection-anchor sel) (selection-head sel) text)))
(define (buffer-op-insert-char ch) (buffer-op-insert (string ch)))
(define (buffer-op-newline)       (buffer-op-insert "\n"))
(define (buffer-op-backspace)
  (lambda (b sel)
    (if (caret? sel)
        (content-backspace-desc (buffer-content b) (selection-head sel))
        (let-values ([(a z) (selection-range sel)]) (edit-desc a z "")))))
(define (buffer-op-delete)
  (lambda (b sel)
    (if (caret? sel)
        (content-delete-desc (buffer-content b) (selection-head sel))
        (let-values ([(a z) (selection-range sel)]) (edit-desc a z "")))))
;; 通用逃生门：显式区间的替换（程序化编辑）
(define (buffer-op-splice start end text) (lambda (_b _sel) (edit-desc start end text)))

;; 用「编辑前的 buffer」取回 d 删掉的文本，求逆。
(define (buffer-edit-desc-inverse b d)
  (edit-desc-inverse d (buffer-range-text b (edit-desc-start d) (edit-desc-end d))))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "hello\nworld"))
  (check-equal? (buffer->string b0) "hello\nworld")
  (check-equal? (buffer->lines b0) '("hello" "world"))
  (check-equal? (buffer-line-count b0) 2)
  (check-equal? (buffer-tick b0) 0)
  (check-true (buffer-content-eq? b0 b0))
  (check-equal? (buffer-line-length b0 0) 5)
  (check-equal? (buffer-line-length b0 99) 5)
  (check-equal? (buffer-clamp-point b0 (point 9 9)) (point 1 5))
  (check-equal? (buffer-point->offset b0 (point 1 0)) 6)
  (check-equal? (buffer-offset->point b0 11) (point 1 5))
  (check-equal? (buffer-range-text b0 (point 0 1) (point 1 2)) "ello\nwo")

  ;; 文本动作只算 desc
  (check-equal? ((buffer-op-insert-char #\X) b0 (caret (point 0 0)))
                (edit-desc (point 0 0) (point 0 0) "X"))
  (check-equal? ((buffer-op-backspace) b0 (caret (point 1 0)))
                (edit-desc (point 0 5) (point 1 0) ""))
  (check-equal? (buffer-clamp-edit-descs b0 (list (edit-desc (point 0 1) (point 0 99) "")))
                (list (edit-desc (point 0 1) (point 0 5) "")))

  ;; 逆由编辑前 buffer 求出
  (define d (edit-desc (point 0 1) (point 0 3) "Z"))
  (check-equal? (buffer-edit-desc-inverse b0 d) (edit-desc (point 0 1) (point 0 2) "el"))

  (displayln "buffer.rkt: all tests passed"))
