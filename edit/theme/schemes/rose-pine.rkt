#lang racket

;;; edit/theme/schemes/rose-pine.rkt —— Rosé Pine 配色（纯数据）
;;; 莫兰迪、素净。

(require "../scheme.rkt"
         "../style.rkt")

(provide rose-pine)

(define rose-pine
  (scheme (rgb 224 222 244)
          (vector (rgb 196 167 231)   ; def      iris
                  (rgb 235 111 146)   ; control  love
                  (rgb 246 193 119)   ; macro    gold
                  (rgb 235 188 186)   ; binding  rose
                  (rgb 156 207 216))  ; module   foam
          (vector (rgb 156 207 216) (rgb 235 188 186) (rgb 246 193 119)
                  (rgb 196 167 231) (rgb 235 111 146) (rgb 49 116 143))
          (vector (rgb 38 34 56) (rgb 30 43 44) (rgb 44 40 32) (rgb 43 32 40))))
