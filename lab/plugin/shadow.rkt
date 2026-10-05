#lang racket

(require "../../core/text/base/line.rkt")

;;; lab/plugin/shadow.rkt —— 插件侧的影子文本（增量同步用）
;;;
;;; worker 和同步 runner 各自维护一份影子文本，主进程只发 **diff**，
;;; 不再每次编辑都整篇序列化。
;;;
;;; shadow = vector of lines（行 = string）。用 core 的 string->lines / lines->string，
;;; 它们保留行尾空行（racket/string 的 string-split 会吞掉尾部空串）。
;;;
;;; edit = (list l0 c0 l1 c1 inserted)：
;;;   把编辑前坐标 [l0,c0)-(l1,c1) 这段替换成 inserted。
;;;   同一批 edit 在**同一编辑前坐标系**、互不重叠 → 从右往左应用，避免坐标漂移。

(provide shadow-open shadow-text shadow-apply)

(define (shadow-open text) (list->vector (string->lines text)))
(define (shadow-text sh) (lines->string (vector->list sh)))

(define (shadow-apply sh edits)
  (for/fold ([sh sh]) ([e (in-list (sort edits edit>?))])
    (apply-one sh e)))

(define (edit>? a b)
  (define la (car a)) (define ca (cadr a))
  (define lb (car b)) (define cb (cadr b))
  (or (> la lb) (and (= la lb) (> ca cb))))

(define (apply-one sh e)
  (match-define (list l0 c0 l1 c1 inserted) e)
  (define ls (vector->list sh))
  (define head (substring (list-ref ls l0) 0 c0))
  (define tail (substring (list-ref ls l1) c1))
  (define ins (string->lines inserted))
  (define block
    (cond
      [(null? (cdr ins)) (list (string-append head (car ins) tail))]     ; 单行：接成一行
      [else
       (append (list (string-append head (car ins)))
               (drop-right (cdr ins) 1)                                   ; 中间整行
               (list (string-append (last ins) tail)))]))
  (list->vector (append (take ls l0) block (drop ls (add1 l1)))))
