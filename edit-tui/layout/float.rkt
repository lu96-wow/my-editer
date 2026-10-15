#lang racket

;;; layout/float.rkt —— 浮窗层（正交覆盖，不参与布局）
;;;
;;; 浮窗只用于补全 / 临时信息，用完即毁：
;;;   · **不进布局树**、不参与权重分配 —— 只是把 panel 叠在平铺 panels 上面；
;;;   · z 由列表顺序决定（表头最上）；floats->panels 给它们分配 deep > 平铺（deep 0）；
;;;   · `key` 是同名替换 / 关闭的句柄（如 'completion / 'docs），用完 floats-remove 即毁。
;;;
;;; 宿主：
;;;   (define ps (append (tree->panels tree area) (floats->panels floats)))
;;;   (render-display-patch ps focus W H cache)
;;;   (panel-at ps row col)            ; 浮窗 deep 高 → 命中浮窗
;;;   (set! floats (floats-remove floats 'completion))
;;;
;;; 浮窗内容就是 core 的 view（与平铺同一套渲染 / 命中），本层只管叠放和几何。

(require "../../core/view/panel.rkt"       ; make-panel / borders-all
         "../../core/view/base/rect.rkt")  ; rect / rect-w / rect-h

(provide (struct-out float)
         make-float float-deep-base
         floats->panels
         floats-add floats-remove floats-ref
         float-rect-at)

(struct float (key view rect borders face) #:transparent)
;; key     : symbol   用途 / 句柄（同名 = 同一个浮窗）
;; view    : core view | #f（#f = 只有框的空面板）
;; rect    : 外框（屏幕坐标）
;; borders : 同 panel
;; face    : 边框 face 符号（默认 'float-border，见 theme/frame.rkt）

;; 平铺 panel 的 deep = 0；浮窗从 base 往上叠，永远盖在平铺之上。
(define float-deep-base 1000)

(define (make-float key view rect
                    #:borders [borders borders-all]
                    #:face [face 'float-border])
  (float key view rect borders face))

;; 表头 = 最上：deep = base + (剩余个数 - 1)。
(define (floats->panels floats)
  (define n (length floats))
  (for/list ([f (in-list floats)] [i (in-naturals)])
    (make-panel (float-view f) (float-rect f) (float-borders f)
                #:deep (+ float-deep-base (- n 1 i))
                #:face (float-face f))))

;; 加 / 提：同 key 的旧浮窗被替换并置顶。
(define (floats-add floats f)
  (cons f (for/list ([x (in-list floats)] #:unless (eq? (float-key x) (float-key f))) x)))

(define (floats-remove floats key)
  (for/list ([x (in-list floats)] #:unless (eq? (float-key x) key)) x))

(define (floats-ref floats key)
  (for/first ([x (in-list floats)] #:when (eq? (float-key x) key)) x))

;; 锚点 (row, col) + 尺寸 (w, h) → 外框。默认放**光标下方、左对齐**；下方放不下翻到上方；
;; 最后夹进 area。给补全弹窗用（其它位置自己造 rect 也行）。
(define (float-rect-at row col w h area)
  (define W (rect-w area)) (define H (rect-h area))
  (define fw (min w W)) (define fh (min h H))
  (define below (add1 row))
  (define y (if (<= (+ below fh) H) below (max 0 (- row fh))))
  (rect (clamp col 0 (max 0 (- W fw)))
        (clamp y 0 (max 0 (- H fh)))
        fw fh))

(define (clamp v lo hi) (max lo (min hi v)))
