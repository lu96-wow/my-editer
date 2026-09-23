#lang racket

(require "point.rkt" "lines.rkt" rackunit)

;;; atom/edit.rkt —— 文本变更原子（edit-desc）+ 位置代数
;;;
;;;   edit-desc     一次替换 [start,end) → new-text（坐标全为「操作前」）
;;;
;;; 位置代数（attrs / 账本 / 视图重基准共用）：
;;;   edit-desc-map-position    编辑前位置 → 编辑后位置（#f = 落在被删区间内）
;;;   edit-desc-after-position  插入文本之后的点
;;;   edit-desc-inverse         由生效 desc + 旧文本求逆
;;;
;;; 「一串 desc」的代数也在这里（doc/viewport 共用）：
;;;   edits-normalize           排序 + 重叠检查
;;;   edits-map-position        把一个点依次映射过一串（施加顺序的）编辑
;;;   edits-span                 一串编辑影响到的行区间并集（增量重绘用）
;;;
;;; 只依赖 point 与 lines，不认识 content/buffer —— 这是最底层的变更原子。

(require racket/list)

(provide
 (struct-out edit-desc)
 edit-desc-map-position
 edit-desc-after-position
 edit-desc-inverse
 edits-normalize
 edits-map-position
 edits-span)

;;; ---------- 数据 ----------

(struct edit-desc (start end new-text) #:transparent)
;; start / end : point     被替换的半开区间 [start, end)（操作前坐标）
;; new-text    : string    取代该区间的文本（可含 \n）

;;; ---------- 批规范化 ----------

;; 输入 descs 都在同一坐标系里、应两两不重叠。返回按起点升序（同起点保持输入次序）
;; 的列表；发现重叠（半开：next.start < prev.end）→ 具名报错。
;; 供 doc 层的批量文本施加与 change 漏斗共用。
(define (edits-normalize who descs)
  (define sorted
    (sort (for/list ([i (in-naturals)] [d (in-list descs)]) (cons i d))
          (lambda (a b)
            (define da (cdr a)) (define db (cdr b))
            (cond [(point<? (edit-desc-start da) (edit-desc-start db)) #t]
                  [(point<? (edit-desc-start db) (edit-desc-start da)) #f]
                  [else (< (car a) (car b))]))))
  (when (>= (length sorted) 2)
    (for ([a (in-list (drop-right sorted 1))] [d (in-list (rest sorted))])
      (when (point<? (edit-desc-start (cdr d)) (edit-desc-end (cdr a)))
        (error who "编辑重叠: ~a 与 ~a" (cdr a) (cdr d)))))
  (map cdr sorted))

;;; ---------- desc 代数（位置如何随一次编辑移动）----------
;; 全部只认 point。

;; 编辑前位置 p → 编辑后位置；返回 point 或 #f（#f = p 落在被删区间内，已不存在）。
(define (edit-desc-map-position d p)
  (define s (edit-desc-start d))
  (define e (edit-desc-end d))
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (define l (point-line p)) (define c (point-col p))
  (define-values (k last-len) (string-line-geom (edit-desc-new-text d)))
  (define delta (- k (- el sl) 1))            ; 行数变化：k - (el-sl+1)
  (cond
    [(or (pos<? l c sl sc) (pos=? l c sl sc)) (point l c)]   ; 起点及之前不动
    [(pos<? l c el ec) #f]                                    ; 落在被删区间内
    [else                                                     ; 在 end 之后
     (cond
       [(= l el)
        (cond
          [(= k 1)   (point sl (+ sc last-len (- c ec)))]     ; 单行插入：含起点列
          [else      (point (+ sl (sub1 k)) (+ last-len (- c ec)))])]
       [else (point (+ l delta) c)])]))

;; 插入文本之后的点（'after' 语义 / 逆编辑的终点 / 光标推进落点）。
(define (edit-desc-after-position d)
  (define s (edit-desc-start d))
  (define text (edit-desc-new-text d))
  (define-values (k last-len) (string-line-geom text))
  (cond
    [(= k 1)   (point (point-line s) (+ (point-col s) (string-length text)))]
    [else      (point (+ (point-line s) (sub1 k)) last-len)]))

;; 逆编辑：抵消 d 的那次编辑。用「d 生效后的新坐标系」表示。
;;   · 区间 = [d.start, d 插入文本之后)
;;   · 文本 = d 删掉的旧文本（调用方传入——edit-desc 不含旧文本）
(define (edit-desc-inverse d old-text)
  (edit-desc (edit-desc-start d) (edit-desc-after-position d) old-text))

;;; ---------- 一串 desc 的代数（位置映射 / 变更行区间）----------

;; 把 p 依次映射过 descs（**施加顺序**）。落在某次删除区间内 → 落到该区间起点。
;; 恰好落在一次零宽插入的点上 → 落到插入文本之后（光标跟随右边文本）。
(define (edits-map-position descs p)
  (for/fold ([p p]) ([d (in-list descs)])
    (cond
      [(and (point=? p (edit-desc-start d))
            (point=? (edit-desc-start d) (edit-desc-end d)))
       (edit-desc-after-position d)]
      [else (or (edit-desc-map-position d p) (edit-desc-start d))])))

;; 一串编辑影响到的行区间并集（新坐标系）：(values 首行 末行)；空 → (values #f #f)。
(define (edits-span descs)
  (for/fold ([f #f] [l #f]) ([d (in-list descs)])
    (define sl (point-line (edit-desc-start d)))
    (define el (+ sl (sub1 (string-line-count (edit-desc-new-text d)))))
    (values (if f (min f sl) sl) (if l (max l el) el))))

;;; ---------- 测试 ----------

(module+ test
  (define d-sp (edit-desc (point 0 1) (point 2 1) "XY\nZ"))
  (check-equal? (edit-desc-map-position d-sp (point 0 0)) (point 0 0))
  (check-equal? (edit-desc-map-position d-sp (point 0 1)) (point 0 1))   ; 起点
  (check-false (edit-desc-map-position d-sp (point 0 2)))               ; 被删
  (check-false (edit-desc-map-position d-sp (point 1 0)))               ; 被删
  (check-equal? (edit-desc-map-position d-sp (point 2 1)) (point 1 1))  ; = end
  (check-equal? (edit-desc-map-position d-sp (point 2 3)) (point 1 3))  ; 同行 end 之后

  (check-equal? (edit-desc-after-position d-sp) (point 1 1))
  (check-equal? (edit-desc-after-position (edit-desc (point 0 3) (point 0 3) "XY")) (point 0 5))
  (check-equal? (edit-desc-after-position (edit-desc (point 2 4) (point 2 4) "中")) (point 2 5))
  (check-equal? (edit-desc-after-position (edit-desc (point 0 1) (point 0 3) "")) (point 0 1))

  (check-equal? (edit-desc-inverse (edit-desc (point 0 2) (point 0 5) "XY") "cde")
                (edit-desc (point 0 2) (point 0 4) "cde"))
  (check-equal? (edit-desc-inverse (edit-desc (point 1 0) (point 2 3) "") "l1\nl2")
                (edit-desc (point 1 0) (point 1 0) "l1\nl2"))
  (check-equal? (edit-desc-inverse (edit-desc (point 0 0) (point 0 0) "X") "")
                (edit-desc (point 0 0) (point 0 1) ""))

  ;; edits-normalize：排序 / 同起点保序 / 重叠报错
  (define (ds* . ds) ds)
  (check-equal? (map edit-desc-start
                     (edits-normalize 'x (list (edit-desc (point 1 0) (point 1 1) "")
                                               (edit-desc (point 0 0) (point 0 1) ""))))
                (list (point 0 0) (point 1 0)))
  (check-equal? (edits-normalize 'x (list (edit-desc (point 0 0) (point 0 0) "A")
                                          (edit-desc (point 0 0) (point 0 0) "B")))
                (list (edit-desc (point 0 0) (point 0 0) "A")
                      (edit-desc (point 0 0) (point 0 0) "B")))
  (check-exn exn:fail?
             (lambda () (edits-normalize 'x (list (edit-desc (point 0 1) (point 0 3) "")
                                                  (edit-desc (point 0 2) (point 0 4) "")))))

  ;; edits-map-position：零宽插入落到插入后；删除区间内吸附起点
  (check-equal? (edits-map-position (list (edit-desc (point 0 1) (point 0 1) "X")) (point 0 1))
                (point 0 2))
  (check-equal? (edits-map-position (list (edit-desc (point 0 1) (point 0 3) "")) (point 0 2))
                (point 0 1))

  ;; edits-span：行区间并集（新坐标系）
  (define (span ds) (call-with-values (lambda () (edits-span ds)) list))
  (check-equal? (span '()) (list #f #f))
  (check-equal? (span (list (edit-desc (point 0 1) (point 0 3) ""))) (list 0 0))
  (check-equal? (span (list (edit-desc (point 1 0) (point 1 0) "M\nN\n"))) (list 1 3))
  (check-equal? (span (list (edit-desc (point 2 0) (point 2 1) "")
                            (edit-desc (point 0 0) (point 0 1) "")))
                (list 0 2))

  (displayln "edit.rkt: all tests passed"))
