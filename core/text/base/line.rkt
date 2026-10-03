#lang racket

(require "track.rkt")

;;; line.rkt —— 行：文本与属性的共同单位
;;;
;;; 一个「格」= 一个字符位：
;;;     文本行 = string（格值 char）
;;;     属性行 = vector（格值 symbol）
;;;
;;; 行按**字符索引**寻址：Racket 的 string 逻辑单位是字符（UTF-8 只是内部编码，
;;; string-length / string-ref 数的是字符），所以文本和属性天然同坐标，
;;; 二者之间不需要换算。换算只发生在「字符索引 ↔ 显示列」（宽字符占 2 列），
;;; 那件事统一在 width.rkt。
;;;
;;; 本文件给出一套**格级**操作，按 string / vector 分派类型：
;;; 上层只需写一份操作，就能同时作用在文本行和属性行上。

(provide
 ;; ---------- 判定 / 度量 ----------
 line? line-length track-line-length

 ;; ---------- 读 ----------
 line-ref line->list

 ;; ---------- 构造 ----------
 line-of-like line-empty-like

 ;; ---------- 写（格级） ----------
 line-slice line-append line-splice line-insert line-delete line-insert-sticky

 ;; ---------- 字符串 ↔ 行 ----------
 string-normalize-newlines string->lines lines->string)

;;; ---------- 字符串 ↔ 行序列（换行归一为 \n） ----------

;; 换行归一：CRLF / 孤立 CR → LF。
(define (string-normalize-newlines s)
  (regexp-replace* #rx"\r\n?" s "\n"))

(define (string->lines s)
  (define ls (string-split (string-normalize-newlines s) "\n" #:trim? #f))
  (if (null? ls) (list "") ls))

(define (lines->string ls) (string-join ls "\n"))

;;; ---------- 格级操作 ----------

;; 一行是否是合法的格序列（string 或 vector 二者之一）。
(define (line? l) (or (string? l) (vector? l)))

;; 格数（= 字符数）。
(define (line-length l)
  (cond [(string? l) (string-length l)]
        [(vector? l) (vector-length l)]
        [else (error 'line-length "不是行（string / vector）: ~a" l)]))

;; 便捷：track 第 i 行的格数（track-ref + line-length 的组合；夹选区 / 算行长常用）。
(define (track-line-length t i) (line-length (track-ref t i)))

;; 第 i 格的值：文本 → char，属性 → symbol。
(define (line-ref l i)
  (cond [(string? l) (string-ref l i)]
        [(vector? l) (vector-ref l i)]
        [else (error 'line-ref "不是行（string / vector）: ~a" l)]))

(define (line->list l)
  (cond [(string? l) (string->list l)]
        [(vector? l) (vector->list l)]
        [else (error 'line->list "不是行（string / vector）: ~a" l)]))

;; 用「像 like 那样的行」装 lst 个格（like 是 string → 得 string；是 vector → 得 vector）。
(define (line-of-like like lst)
  (cond [(string? like) (list->string lst)]
        [(vector? like) (list->vector lst)]
        [else (error 'line-of-like "不是行（string / vector）: ~a" like)]))

(define (line-empty-like like)
  (cond [(string? like) ""]
        [(vector? like) (vector)]
        [else (error 'line-empty-like "不是行（string / vector）: ~a" like)]))

;; 半开区间 [s,e) 的子序列（与 like 同类型）。
(define (line-slice l s e)
  (cond [(string? l) (substring l s e)]
        [(vector? l) (vector-copy l s e)]
        [else (error 'line-slice "不是行（string / vector）: ~a" l)]))

(define (line-append a b)
  (cond [(string? a) (string-append a b)]
        [(vector? a) (vector-append a b)]
        [else (error 'line-append "不是行（string / vector）: ~a" a)]))

;; 把 [s,e) 的格换成 items（items 与 l 同类型）。
(define (line-splice l s e items)
  (line-append (line-append (line-slice l 0 s) items) (line-slice l e (line-length l))))

(define (line-insert l i items) (line-splice l i i items))

;; 删除 [s,e)：新内容为空，但类型须与 l 一致 —— 用 l 自己的空子序列。
(define (line-delete l s e) (line-splice l s e (line-slice l s s)))

;; 在 gap i 插入 n 个格：
;;   'none   填 default
;;   'left   复制左邻（i-1）
;;   'right  复制右邻（i）
;; 无邻居（0 / 末尾）时回退 default。文本与属性通用。
(define (line-insert-sticky l i n dir [default #f])
  (define val
    (case dir
      [(none) default]
      [(left) (if (> i 0) (line-ref l (sub1 i)) default)]
      [(right) (if (< i (line-length l)) (line-ref l i) default)]
      [else (error 'line-insert-sticky "dir 必须是 'none / 'left / 'right，得到 ~a" dir)]))
  (line-splice l i i (line-of-like l (make-list n val))))
