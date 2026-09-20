#lang racket

(require "point.rkt" "lines.rkt" rackunit)

;;; atom/edit.rkt —— 编辑描述（唯一跨层契约）+ 位置代数
;;;
;;;   edit-desc     一次替换 [start,end) → new-text（坐标全为「操作前」）
;;;   edit-change   一次编辑的完整材料（desc + 逆 + 编辑前光标）
;;;
;;; 位置代数（restrictions / 账本 / 视图重基准共用）：
;;;   edit-desc-map-position    编辑前位置 → 编辑后位置（#f = 落在被删区间内）
;;;   edit-desc-after-position  插入文本之后的点
;;;   edit-desc-inverse         由生效 desc + 旧文本求逆
;;;
;;; 只依赖 point 与 lines，不认识 content/buffer —— 这是最底层的变更原子。

(provide
 (struct-out edit-desc)
 (struct-out edit-change)
 edit-desc-map-position
 edit-desc-after-position
 edit-desc-inverse)

;;; ---------- 数据 ----------

(struct edit-desc (start end new-text) #:transparent)
;; start / end : point     被替换的半开区间 [start, end)（操作前坐标）
;; new-text    : string    取代该区间的文本（可含 \n）

;; 一次编辑的**完整材料**。desc 与 inverse 同为 edit-desc，散着传写反了不报错，
;; 打包让这个错变成编译错。pre-point 由持光标的层（window/command）填。
(struct edit-change (desc inverse pre-point) #:transparent)
;; desc        : edit-desc  这次编辑（操作前坐标）—— 重放用它
;; inverse     : edit-desc  逆（操作后坐标，由编辑前的 buffer 导出）—— 撤销用它
;; pre-point   : point      编辑视图在编辑前的光标 —— 撤销后回到这里

;;; ---------- desc 代数（位置如何随一次编辑移动）----------
;; 全部只认 point。

;; 编辑前位置 p → 编辑后位置；返回 point 或 #f（#f = p 落在被删区间内，已不存在）。
(define (edit-desc-map-position d p)
  (define s (edit-desc-start d))
  (define e (edit-desc-end d))
  (define sl (point-line s)) (define sc (point-col s))
  (define el (point-line e)) (define ec (point-col e))
  (define l (point-line p)) (define c (point-col p))
  (define new-lines (string->lines (edit-desc-new-text d)))
  (define k (length new-lines))
  (define last-len (if (zero? k) 0 (string-length (last new-lines))))
  (define delta (- k (- el sl) 1))            ; 行数变化：k - (el-sl+1)
  (cond
    [(or (pos<? l c sl sc) (pos=? l c sl sc)) (point l c)]   ; 起点及之前不动
    [(pos<? l c el ec) #f]                                    ; 落在被删区间内
    [else                                                     ; 在 end 之后
     (cond
       [(= l el)
        (cond
          [(zero? k) (point sl (+ sc (- c ec)))]              ; 纯删除：接回起点之后
          [(= k 1)   (point sl (+ sc last-len (- c ec)))]     ; 单行插入：含起点列
          [else      (point (+ sl (sub1 k)) (+ last-len (- c ec)))])]
       [else (point (+ l delta) c)])]))

;; 插入文本之后的点（'after' 语义 / 逆编辑的终点 / 光标推进落点）。
(define (edit-desc-after-position d)
  (define s (edit-desc-start d))
  (define new-lines (string->lines (edit-desc-new-text d)))
  (define k (length new-lines))
  (cond
    [(zero? k) (point (point-line s) (point-col s))]                    ; 纯删除 → 回到起点
    [(= k 1)   (point (point-line s) (+ (point-col s) (string-length (car new-lines))))]
    [else      (point (+ (point-line s) (sub1 k)) (string-length (last new-lines)))]))

;; 逆编辑：抵消 d 的那次编辑。用「d 生效后的新坐标系」表示。
;;   · 区间 = [d.start, d 插入文本之后)
;;   · 文本 = d 删掉的旧文本（调用方传入——edit-desc 不含旧文本）
(define (edit-desc-inverse d old-text)
  (edit-desc (edit-desc-start d) (edit-desc-after-position d) old-text))

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

  ;; edit-change 打包
  (check-equal? (edit-change-desc (edit-change d-sp d-sp (point 0 0))) d-sp)

  (displayln "edit.rkt: all tests passed"))
