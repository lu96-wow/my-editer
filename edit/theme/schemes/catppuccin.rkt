#lang racket

;;; edit/theme/schemes/catppuccin.rkt —— Catppuccin Mocha 配色（纯数据）
;;; 暖、粉调、柔和。

(require "../scheme.rkt"
         "../style.rkt")

(provide catppuccin)

(define catppuccin
  (scheme (rgb 205 214 244)
          (vector (rgb 203 166 247)   ; def      mauve
                  (rgb 243 139 168)   ; control  red
                  (rgb 250 179 135)   ; macro    peach
                  (rgb 180 190 254)   ; binding  lavender
                  (rgb 137 180 250))  ; module   blue
          (vector (rgb 245 194 231) (rgb 148 226 213) (rgb 166 227 161)
                  (rgb 249 226 175) (rgb 137 180 250) (rgb 250 179 135))
          (vector (rgb 42 39 64) (rgb 30 48 56) (rgb 50 46 34) (rgb 35 44 66))))
