#lang racket

;;; edit/theme/schemes/tokyo-night.rkt —— Tokyo Night 配色（纯数据）
;;; 现代、略艳但和谐。

(require "../scheme.rkt"
         "../style.rkt")

(provide tokyo-night)

(define tokyo-night
  (scheme (rgb 192 202 245)
          (vector (rgb 187 154 247)   ; def      purple
                  (rgb 247 118 142)   ; control  red
                  (rgb 224 175 104)   ; macro    yellow
                  (rgb 125 207 255)   ; binding  cyan
                  (rgb 122 162 247))  ; module   blue
          (vector (rgb 125 207 255) (rgb 158 206 106) (rgb 224 175 104)
                  (rgb 255 158 100) (rgb 187 154 247) (rgb 247 118 142))
          (vector (rgb 36 31 56) (rgb 28 42 51) (rgb 44 39 29) (rgb 43 30 42))))
