using System;

namespace SQL_AE_Test.Models
{
    public class Customer
    {
        public required int Id { get; set; }
        public required string SSN { get; set; }
        public required DateTime BirthDate { get; set; }
    }
}