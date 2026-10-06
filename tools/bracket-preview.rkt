#lang racket

;;; lab/tools/bracket-preview.rkt —— 括号深度配色「设计器 + 预览」
;;;
;;;   racket tools/bracket-preview.rkt
;;;
;;; 颜色空间：OKLab / OKLCH（Björn Ottosson）—— 感知均匀，适合设计。
;;; 在这里直接定 L（感知亮度，0-1）、C（彩度，0 起）、h（色相，角度），
;;; 再转回 sRGB。好处：
;;;   · 亮度与色相解耦 → 可以「整体压暗」同时「色相均匀旋转」；
;;;   · 感知均匀 → 相邻档的感知距离（ΔE）可算、可调均匀；
;;;   · 暗色不发灰：同 L 下能取到更高彩度（sRGB 内自动裁）。
;;;
;;; 当前设计：h 25°(红橙) → 325°(品红)，走完整色相（红→琥珀→橄榄→绿→青→蓝→紫→品红）；
;;;   L 0.30→0.52，C 0.07→0.13。跳得大、区分度高，但整体仍偏暗。
;;;   → 相邻 ΔE≈0.061…0.097（比之前大一倍）。
;;; 参数在下面「设计参数」处改，脚本会打印可直接粘贴进主题的 RGB 字面量。
;;; 想更柔和：C1 降到 0.09 左右；想跳更大：N 降到 6–7。

(require tui
         racket/string
         racket/format)

(define (hx v) (string-append (if (< v 16) "0" "") (number->string v 16)))
(define (hex c) (string-append "#" (hx (car c)) (hx (cadr c)) (hx (caddr c))))

;;; ================= OKLab / OKLCH ↔ sRGB =================

(define (srgb->lin c) (if (<= c 0.04045) (/ c 12.92) (expt (/ (+ c 0.055) 1.055) 2.4)))
(define (lin->srgb c) (if (<= c 0.0031308) (* 12.92 c) (- (* 1.055 (expt c (/ 1 2.4))) 0.055)))
(define (cbrt x) (if (negative? x) (- (expt (- x) (/ 1 3.0))) (expt x (/ 1 3.0))))

(define (oklab->lin L a b)
  (define l_ (+ L (* 0.3963377774 a) (* 0.2158037573 b)))
  (define m_ (+ L (* -0.1055613458 a) (* -0.0638541728 b)))
  (define s_ (+ L (* -0.0894841775 a) (* -1.2914855480 b)))
  (define l (expt l_ 3)) (define m (expt m_ 3)) (define s (expt s_ 3))
  (list (+ (* 4.0767416621 l) (* -3.3077115913 m) (* 0.2309699292 s))
        (+ (* -1.2684380046 l) (* 2.6097574011 m) (* -0.3413193965 s))
        (+ (* -0.0041960863 l) (* -0.7034186147 m) (* 1.7076147010 s))))

(define (oklch->oklab L C h) (list L (* C (cos h)) (* C (sin h))))
(define (deg->rad d) (* d (/ pi 180.)))
(define (rad->deg r) (* r (/ 180. pi)))

(define (in-gamut? L a b)
  (for/and ([c (oklab->lin L a b)]) (and (>= c -0.0005) (<= c 1.0005))))

;; sRGB 内允许的最大 C（保 L、h）——避免超界裁切导致色相偏移
(define (fit-C L h Cmax)
  (let loop ([lo 0.0] [hi Cmax] [i 0])
    (cond [(>= i 24) lo]
          [else
           (define mid (/ (+ lo hi) 2))
           (define ab (oklch->oklab L mid h))
           (if (in-gamut? L (cadr ab) (caddr ab)) (loop mid hi (add1 i)) (loop lo mid (add1 i)))])))

(define (oklch->rgb255 L C h)
  (define ab (oklch->oklab L C h))
  (for/list ([c (oklab->lin L (cadr ab) (caddr ab))])
    (inexact->exact (round (* 255 (max 0 (min 1 (lin->srgb c))))))))

;;; ================= 设计参数（改这里） =================

(define N 8)                      ; 档数（= 最深可区分的层数，之后截断）；少 → 相邻跳更大
(define hue0 25)                  ; 起点色相（OKLCH 角）：红橙
(define hue1 325)                 ; 终点色相：品红（走完整色相）
(define L0 0.30)                  ; 最浅层亮度（越低越暗）
(define L1 0.52)                  ; 最深层亮度
(define C0 0.07)                  ; 最浅层彩度
(define C1 0.13)                  ; 最深层彩度

;; 每档 = (rgb L C h)
(define entries
  (for/list ([i (in-range N)])
    (define t (/ i (sub1 N)))
    (define h (deg->rad (+ hue0 (* (- hue1 hue0) t))))
    (define L (+ L0 (* (- L1 L0) t)))
    (define C (fit-C L h (+ C0 (* (- C1 C0) t))))
    (list (oklch->rgb255 L C h) L C (rad->deg h))))

(define bracket-palette (list->vector (map (lambda (e) (list #f (car e))) entries)))

(define (ok-dist p q)
  (define (to-lab e) (define ab (oklch->oklab (cadr e) (caddr e) (deg->rad (cadddr e)))) (list (cadr e) (cadr ab) (caddr ab)))
  (define a (to-lab p)) (define b (to-lab q))
  (sqrt (for/sum ([x a] [y b]) (sqr (- x y)))))

;;; ================= 输出 =================

(define reset-str (bytes->string/utf-8 format-reset))
(define (depth-bg depth)
  (define b (cadr (vector-ref bracket-palette (min depth (sub1 (vector-length bracket-palette))))))
  (bytes->string/utf-8 (apply format-rgb-bg-base b)))
(define (swatch depth text) (string-append (depth-bg depth) text reset-str))

(define (print-legend)
  (displayln "\n括号深度配色（OKLCH 设计 → sRGB；背景色）")
  (displayln (make-string 60 #\─))
  (for ([e (in-list entries)] [i (in-naturals)])
    (define rgb (car e))
    (printf "d~a  " i)
    (display (swatch i "          "))
    (printf "  ~a  ~a  L~a C~a h~a~a\n"
            (hex rgb) rgb
            (real->decimal-string (cadr e) 2)
            (real->decimal-string (caddr e) 3)
            (real->decimal-string (cadddr e) 0)
            (if (zero? i) "" (format "   ΔE~a" (real->decimal-string (ok-dist (list-ref entries (sub1 i)) e) 3)))))
  (displayln ""))

(define (print-literal)
  (displayln "粘贴进 config/theme/dark.rkt / light.rkt 的 'bracket 向量：")
  (display "  'bracket (vector")
  (for ([e (in-list entries)])
    (printf "~%           (list #f '~s)" (car e)))
  (displayln ")")
  (displayln ""))

;;; ================= 按「最内层括号对」给示例着色（与 lab 的 bracket-fills 一致） =================

(define (open? c) (or (char=? c #\() (char=? c #\[) (char=? c #\{)))
(define (close? c) (or (char=? c #\)) (char=? c #\]) (char=? c #\})))

(define (colorize text)
  (define out (open-output-string))
  (define stack '())                       ; 元素 = 层号
  (for ([c (in-string text)])
    (define depth
      (cond
        [(open? c) (define d (length stack)) (set! stack (cons d stack)) d]
        [(and (close? c) (pair? stack)) (set! stack (cdr stack)) (length stack)]
        [(pair? stack) (car stack)]
        [else #f]))
    (write-string (if depth (swatch depth (string c)) (string c)) out))
  (get-output-string out))

(define sample
  (string-append
   "(define (tree-sum t)\n"
   "  (cond [(null? t) 0]\n"
   "        [(pair? t) (+ (tree-sum (car t))\n"
   "                      (tree-sum (cdr t)))]\n"
   "        [else (vector-ref (list->vector (list t))\n"
   "                          (hash-ref (make-hash (list (cons 'k (cons 1 2)))) 'k))]))\n"))

(define deep
  "(a (b (c (d (e (f (g (h (i (j (k (l (m (n o))))))))))))))\n")

(define (section title text)
  (displayln title)
  (displayln (make-string 60 #\─))
  (displayln (colorize text))
  (displayln ""))

(print-legend)
(print-literal)
(section "示例：按最内层括号对深度着色" sample)
(section (format "深层嵌套：超过 ~a 层后截断在最后一档（不再变暗）" N) deep)
