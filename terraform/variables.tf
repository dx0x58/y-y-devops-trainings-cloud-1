variable "image_tag" {
  description = "image_tag"
  type        = string

  validation {
    condition     = length(var.image_tag) > 0
    error_message = "The image_tag must not be empty."
  }
}