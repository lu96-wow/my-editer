#lang racket

;;; lab/base/layout/area.rkt —— 屏幕矩形区域与切分（骨架）
;;;
;;; 纯几何：一块 area（列 x、行 y、宽 w、高 h）按方向切成两段。
;;; 不认识 pane、不认识 view、不认识窗口其它部分。
;;;
;;; 待定：
;;;   - 坐标 / 宽高是「格」还是「像素」？当前按格（TUI 直接；GUI 在边界换算）。
;;;   - 要不要 gap / 分隔线字段？（当前没有，切分即紧贴）

(provide (struct-out area)
         area-split area-split/gap area-contains?)

;; 一块矩形区域：屏幕列 x、屏幕行 y、宽 w、高 h。
(struct area (x y width height) #:transparent)

;; 按 dir 把 a 切成两段：
;;   'lr  左右，第一段宽 size
;;   'tb  上下，第一段高 size
(define (area-split a dir size)
  (case dir
    [(lr) (values (area (area-x a) (area-y a) size (area-height a))
                  (area (+ (area-x a) size) (area-y a) (- (area-width a) size) (area-height a)))]
    [(tb) (values (area (area-x a) (area-y a) (area-width a) size)
                  (area (area-x a) (+ (area-y a) size) (area-width a) (- (area-height a) size)))]
    [else (error 'area-split "dir 必须是 'lr / 'tb，得到 ~a" dir)]))

(define (area-contains? a r c)
  (and (>= r (area-y a)) (< r (+ (area-y a) (area-height a)))
       (>= c (area-x a)) (< c (+ (area-x a) (area-width a)))))

;; 带 gap 的切分：两段之间有 gap 宽 / 高的**分割条**。
;; → (values 第一段 bar 第二段)；bar 是中间那条（dir='lr 时宽 gap，'tb 时高 gap）。
(define (area-split/gap a dir size gap)
  (case dir
    [(lr) (values (area (area-x a) (area-y a) size (area-height a))
                  (area (+ (area-x a) size) (area-y a) gap (area-height a))
                  (area (+ (area-x a) size gap) (area-y a)
                        (- (area-width a) size gap) (area-height a)))]
    [(tb) (values (area (area-x a) (area-y a) (area-width a) size)
                  (area (area-x a) (+ (area-y a) size) (area-width a) gap)
                  (area (area-x a) (+ (area-y a) size gap)
                        (area-width a) (- (area-height a) size gap)))]
    [else (error 'area-split/gap "dir 必须是 'lr / 'tb，得到 ~a" dir)]))
