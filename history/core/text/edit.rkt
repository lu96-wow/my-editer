#lang racket

(require "point.rkt" "content.rkt" "buffer.rkt" rackunit)

;;; edit.rkt —— 批量编辑应用原语（编辑插件的 core 侧机制）
;;;
;;; 一次编辑 = 一个 edit-desc（统一 splice）。本模块提供：
;;;   - buffer-apply-edit-batch   : 把一批「同一坐标系」的编辑原子应用到 buffer
;;;   - edits-map-position : 把一个点依次映射过一串「应用顺序」的编辑
;;;   - edits-span         : 一串编辑影响到的**行区间并集**（按文本行做增量重绘用）
;;;
;;; 纯函数，数据 -> lambda -> 数据，无任何副作用/线程。

(provide
 buffer-apply-edit-batch
 edits-map-position
 edits-span)

;;; ---------- 位置比较 ----------
;; pos<? / pos=? 的唯一实现在 point.rkt（本模块 require 它）。

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
;; 供上层按序映射 point（见 edits-map-position）。
(define (buffer-apply-edit-batch b edits)
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
         (error 'buffer-apply-edit-batch "编辑重叠: ~a 与 ~a" a d)))
     ;; 倒序应用。descs 用 cons 累积（每次 O(1)，避免 append 的 O(n²)），
     ;; 最后 reverse 回「应用顺序」供上层按序映射 point。
     ;; desc=#f（no-op / 被 read-only 拒绝）的编辑没有发生，不参与映射。
     (let-values ([(b* descs)
                   (for/fold ([b b] [acc '()])
                             ([d (in-list (reverse sorted))])
                     (define-values (b2 dd)
                       (buffer-splice b
                                      (edit-desc-s-line d) (edit-desc-s-col d)
                                      (edit-desc-e-line d) (edit-desc-e-col d)
                                      (edit-desc-new-text d)))
                     (values b2 (if dd (cons dd acc) acc)))])
       (values b* (reverse descs)))]))

;;; ---------- 点映射（跨一串应用顺序的编辑）----------

;; 把 (line col) 依次映射过 descs（应用顺序）。落在某次删除区间内 → 落到该区间起点。
(define (edits-map-position descs line col)
  (let loop ([l line] [c col] [ds descs])
    (cond
      [(null? ds) (point l c)]
      [else
       (define d (car ds))
       ;; 点恰在零宽插入点 → 落到插入文本之后（window point 的 after 语义：跟随原字符）
       (cond
         [(and (= l (edit-desc-s-line d)) (= c (edit-desc-s-col d))
               (= (edit-desc-s-line d) (edit-desc-e-line d))
               (= (edit-desc-s-col d) (edit-desc-e-col d)))
          (define ap (edit-desc-after-position d))
          (loop (point-line ap) (point-col ap) (cdr ds))]
         [else
          (define m (edit-desc-map-position d l c))
          (if m
              (loop (point-line m) (point-col m) (cdr ds))
              (point (edit-desc-s-line d) (edit-desc-s-col d)))])])))

;;; ---------- 行区间并集（增量重绘用）----------

;; 一串（应用顺序的）编辑影响到的**行区间并集**，用新坐标系：返回 (values 首行 末行)。
;; 空 → (values #f #f)（与 window-point->screen 的"没有"同一形状）。
;; 单条 desc 的区间 = [s-line, s-line + 新文本行数 - 1]：新文本为空 → 占 1 行，所以正是 s-line。
;;
;; 用途：按文本行做增量重绘（单次编辑同样适用——一条 desc 的区间就是这次改动的行）。
;; **行数平移量（old→new）desc 里没有**，要的话编辑前后各读一次 buffer-line-count（O(1)）。
(define (edits-span descs)
  (for/fold ([fr #f] [lr #f]) ([d (in-list descs)])
    (define s (edit-desc-s-line d))
    (define e (+ s (sub1 (length (string->lines (edit-desc-new-text d))))))
    (values (if fr (min fr s) s) (if lr (max lr e) e))))

;;; ---------- 测试 ----------

(module+ test
  (define b0 (buffer-open "abcd\nefgh"))

  ;; 空批 → 原样
  (define-values (be de) (buffer-apply-edit-batch b0 '()))
  (check-eq? be b0)
  (check-equal? de '())

  ;; 两个不相交插入：倒序应用，坐标互不干扰
  (define-values (b1 d1s)
    (buffer-apply-edit-batch b0
      (list (edit-desc 0 1 0 1 "X")   ; aXbcd
            (edit-desc 1 2 1 2 "Y")))) ; efYgh
  (check-equal? (buffer->string b1) "aXbcd\nefYgh")

  ;; 点映射：原 (0,2) 的 'c' 经过「0,1 插入 X」后应到 (0,3)
  (check-equal? (edits-map-position d1s 0 2) (point 0 3))
  ;; 原 (1,2) 的 'g' 经过两个插入后应到 (1,3)
  (check-equal? (edits-map-position d1s 1 2) (point 1 3))

  ;; 跨行删除 + 插入
  (define-values (b2 d2s)
    (buffer-apply-edit-batch b0 (list (edit-desc 0 1 1 2 "Z\nW"))))
  (check-equal? (buffer->string b2) "aZ\nWgh")

  ;; 重叠 → 报错
  (check-exn exn:fail?
             (lambda () (buffer-apply-edit-batch b0
                          (list (edit-desc 0 1 0 3 "X")
                                (edit-desc 0 2 0 4 "Y")))))

  ;; 同起点零宽插入：按列表顺序确定
  (define-values (b3 _d3)
    (buffer-apply-edit-batch b0 (list (edit-desc 0 0 0 0 "A")
                                 (edit-desc 0 0 0 0 "B"))))
  (check-equal? (buffer->string b3) "ABabcd\nefgh")

  ;; 被 read-only 拒绝的编辑没发生：desc=#f 不进结果，不污染后续点映射
  (define rbd (buffer-put-restrict (buffer-open "abcd") 0 0 2 (restrict #t)))
  (define-values (rb* rdescs)
    (buffer-apply-edit-batch rbd (list (edit-desc 0 1 0 1 "X")     ; 在 read-only 内 → 拒绝
                                  (edit-desc 0 3 0 3 "Y"))))  ; 允许
  (check-equal? (buffer->string rb*) "abcYd")
  (check-equal? rdescs (list (edit-desc 0 3 0 3 "Y")))

  ;; ---- edits-span：一组编辑的行区间并集（新坐标系）----
  (define (span ds) (call-with-values (lambda () (edits-span ds)) list))
  (check-equal? (span '()) (list #f #f))                                    ; 什么都没发生
  (check-equal? (span (list (edit-desc 0 1 0 3 ""))) (list 0 0))            ; 纯删除 → 占 1 行
  (check-equal? (span (list (edit-desc 0 1 0 1 "X"))) (list 0 0))           ; 单字符插入
  (check-equal? (span (list (edit-desc 1 0 1 0 "M\nN\n"))) (list 1 3))      ; 插 3 行文本
  (check-equal? (span (list (edit-desc 0 0 2 3 ""))) (list 0 0))            ; 删 3 行
  ;; 并集：行 2 与行 0 两条 → (0 2)；顺序无关
  (check-equal? (span (list (edit-desc 2 0 2 1 "") (edit-desc 0 0 0 1 ""))) (list 0 2))
  (check-equal? (span (list (edit-desc 0 0 0 1 "") (edit-desc 2 0 2 1 ""))) (list 0 2))

  ;; 真实用途：整组落回后取「哪些行要重画」（新坐标系）
  (define gb0 (buffer-open "aaa\nbbb\nccc"))
  (define gdescs (list (edit-desc 0 0 0 1 "") (edit-desc 2 0 2 1 "")))
  (define-values (gb1 _g1) (buffer-apply-edit-trusted gb0 (car gdescs)))
  (define-values (gb2 _g2) (buffer-apply-edit-trusted gb1 (cadr gdescs)))
  (check-equal? (buffer->string gb2) "aa\nbbb\ncc")
  (check-equal? (span gdescs) (list 0 2))          ; 行 0 与行 2 都要重画

  (displayln "edit.rkt: all tests passed"))
