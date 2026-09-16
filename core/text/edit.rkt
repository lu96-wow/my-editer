#lang racket

(require "cursor.rkt" "content.rkt" "buffer.rkt" rackunit)

;;; edit.rkt —— 批量编辑应用原语（编辑插件的 core 侧机制）
;;;
;;; 一次编辑 = 一个 edit-desc（统一 splice）。本模块提供：
;;;   - buffer-apply-edits   : 把一批「同一坐标系」的编辑原子应用到 buffer
;;;   - edit-descs-map-position : 把一个点依次映射过一串「应用顺序」的编辑
;;;
;;; 纯函数，数据 -> lambda -> 数据，无任何副作用/线程。

(provide
 buffer-apply-edits
 edit-descs-map-position)

;;; ---------- 位置比较（(line col) 字典序，0-based）----------

(define (pos<? l1 c1 l2 c2)
  (or (< l1 l2) (and (= l1 l2) (< c1 c2))))

;; edit-desc 按起点 (s-line s-col) 字典序比较
(define (edit-start<? a b)
  (or (< (edit-desc-s-line a) (edit-desc-s-line b))
      (and (= (edit-desc-s-line a) (edit-desc-s-line b))
           (< (edit-desc-s-col a) (edit-desc-s-col b)))))

;;; ---------- 批量应用 ----------

;; 输入 edits 全部在 b 的坐标系里（互相独立、不重叠）。
;; 按起点倒序应用：先改后面的位置，不移动前面未处理位置的坐标，免去逐个重定位。
;; 重叠（含跨行）→ 报错；同起点零宽插入按原列表顺序确定性地应用。
;; 返回 (values 新 buffer (listof edit-desc))，descs 为「应用顺序」（倒序位置），
;; 供上层按序映射 point（见 edit-descs-map-position）。
(define (buffer-apply-edits b edits)
  (cond
    [(null? edits) (values b '())]
    [else
     ;; 稳定总序：起点字典序，同起点按原列表下标
     (define sorted
       (let ([indexed (for/list ([i (in-naturals)] [e (in-list edits)])
                        (cons i e))])
         (map cdr
              (sort indexed
                    (lambda (a b)
                      (define ea (cdr a)) (define eb (cdr b))
                      (cond [(edit-start<? ea eb) #t]
                            [(edit-start<? eb ea) #f]
                            [else (< (car a) (car b))]))))))
     ;; 升序检查相邻是否重叠（半开区间：d.start < a.end 即重叠）
     (for ([a (in-list (drop-right sorted 1))]
           [d (in-list (rest sorted))])
       (when (pos<? (edit-desc-s-line d) (edit-desc-s-col d)
                    (edit-desc-e-line a) (edit-desc-e-col a))
         (error 'buffer-apply-edits "编辑重叠: ~a 与 ~a" a d)))
     ;; 倒序应用，按应用顺序收集 desc（供上层按序映射 point）
     (for/fold ([b b] [descs '()])
               ([d (in-list (reverse sorted))])
       (define-values (b2 dd)
         (buffer-splice b
                        (edit-desc-s-line d) (edit-desc-s-col d)
                        (edit-desc-e-line d) (edit-desc-e-col d)
                        (edit-desc-new-text d)))
       (values b2 (append descs (list dd))))]))

;;; ---------- 点映射（跨一串应用顺序的编辑）----------

;; 把 (line col) 依次映射过 descs（应用顺序）。落在某次删除区间内 → 落到该区间起点。
(define (edit-descs-map-position descs line col)
  (let loop ([l line] [c col] [ds descs])
    (cond
      [(null? ds) (cursor l c)]
      [else
       (define d (car ds))
       ;; 点恰在零宽插入点 → 落到插入文本之后（window point 的 after 语义：跟随原字符）
       (cond
         [(and (= l (edit-desc-s-line d)) (= c (edit-desc-s-col d))
               (= (edit-desc-s-line d) (edit-desc-e-line d))
               (= (edit-desc-s-col d) (edit-desc-e-col d)))
          (define ap (edit-desc-after-position d))
          (loop (cursor-line ap) (cursor-col ap) (cdr ds))]
         [else
          (define m (edit-desc-map-position d l c))
          (if m
              (loop (cursor-line m) (cursor-col m) (cdr ds))
              (cursor (edit-desc-s-line d) (edit-desc-s-col d)))])])))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "abcd\nefgh"))

  ;; 空批 → 原样
  (define-values (be de) (buffer-apply-edits b0 '()))
  (check-eq? be b0)
  (check-equal? de '())

  ;; 两个不相交插入：倒序应用，坐标互不干扰
  (define-values (b1 d1s)
    (buffer-apply-edits b0
      (list (edit-desc 0 1 0 1 "X")   ; aXbcd
            (edit-desc 1 2 1 2 "Y")))) ; efYgh
  (check-equal? (buffer->string b1) "aXbcd\nefYgh")

  ;; 点映射：原 (0,2) 的 'c' 经过「0,1 插入 X」后应到 (0,3)
  (check-equal? (edit-descs-map-position d1s 0 2) (cursor 0 3))
  ;; 原 (1,2) 的 'g' 经过两个插入后应到 (1,3)
  (check-equal? (edit-descs-map-position d1s 1 2) (cursor 1 3))

  ;; 跨行删除 + 插入
  (define-values (b2 d2s)
    (buffer-apply-edits b0 (list (edit-desc 0 1 1 2 "Z\nW"))))
  (check-equal? (buffer->string b2) "aZ\nWgh")

  ;; 重叠 → 报错
  (check-exn exn:fail?
             (lambda () (buffer-apply-edits b0
                          (list (edit-desc 0 1 0 3 "X")
                                (edit-desc 0 2 0 4 "Y")))))

  ;; 同起点零宽插入：按列表顺序确定
  (define-values (b3 _d3)
    (buffer-apply-edits b0 (list (edit-desc 0 0 0 0 "A")
                                 (edit-desc 0 0 0 0 "B"))))
  (check-equal? (buffer->string b3) "ABabcd\nefgh")

  (displayln "edit.rkt: all tests passed"))
